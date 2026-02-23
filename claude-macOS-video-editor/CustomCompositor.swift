import AVFoundation
import CoreImage
import CoreMedia
import AppKit

// MARK: - Compositor Instruction

nonisolated final class CustomCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = true
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layerRenderData: [CMPersistentTrackID: LayerRenderData]
    let textOverlays: [TextOverlay]

    struct LayerRenderData: Sendable {
        let trackID: CMPersistentTrackID
        let transform: CGAffineTransform
        let offsetX: CGFloat
        let offsetY: CGFloat
        let scale: CGFloat
        let rotation: CGFloat  // degrees
        let exposure: Float
        let filter: VideoFilter
        let filterIntensity: Float
        let zOrder: Int
        // Keyframe animation data — carry the full clip for per-frame interpolation
        let clipKeyframes: [ClipKeyframe]
        let clipStartTimeInTimeline: CMTime
        let clipTrimmedDuration: CMTime
    }

    init(
        timeRange: CMTimeRange,
        sourceTrackIDs: [CMPersistentTrackID],
        layerRenderData: [CMPersistentTrackID: LayerRenderData],
        textOverlays: [TextOverlay]
    ) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: $0) }
        self.layerRenderData = layerRenderData
        self.textOverlays = textOverlays
        super.init()
    }
}

// MARK: - Custom Video Compositor

nonisolated final class CustomVideoCompositor: NSObject, AVVideoCompositing {

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self.processRequest(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: - Frame Processing

    private func processRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction
                as? CustomCompositorInstruction else {
            request.finish(with: NSError(domain: "CustomCompositor", code: -1))
            return
        }

        let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
        let renderRect = CGRect(origin: .zero, size: renderSize)

        // Sort layers by z-order (track 0 at bottom)
        let sortedLayers = instruction.layerRenderData.values
            .sorted { $0.zOrder < $1.zOrder }

        // Start with black background
        var composited = CIImage(color: .black).cropped(to: renderRect)

        // Composite each layer
        for layerData in sortedLayers {
            guard let sourceBuffer = request.sourceFrame(byTrackID: layerData.trackID) else {
                continue
            }

            var image = CIImage(cvPixelBuffer: sourceBuffer)
            let sourceExtent = image.extent

            // Apply asset preferred transform to handle rotation/flip.
            // The raw transform includes translation values that may shift the image
            // off-screen, so we apply the transform then normalize to origin.
            let transform = layerData.transform
            let isIdentity = transform == .identity
            if !isIdentity {
                image = image.transformed(by: transform)
                // Normalize: move image so its origin is at (0,0)
                let shifted = image.extent
                if shifted.origin.x != 0 || shifted.origin.y != 0 {
                    image = image.transformed(by: CGAffineTransform(
                        translationX: -shifted.origin.x,
                        y: -shifted.origin.y
                    ))
                }
            }

            // Fit the image into render size
            let imageExtent = image.extent
            if imageExtent.width > 0 && imageExtent.height > 0 {
                let fitScaleX = renderSize.width / imageExtent.width
                let fitScaleY = renderSize.height / imageExtent.height
                let fitScale = min(fitScaleX, fitScaleY)

                if abs(fitScale - 1.0) > 0.001 {
                    image = image.transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
                }

                // Center in render frame
                let fitted = image.extent
                let centerX = (renderSize.width - fitted.width) / 2 - fitted.origin.x
                let centerY = (renderSize.height - fitted.height) / 2 - fitted.origin.y
                image = image.transformed(by: CGAffineTransform(translationX: centerX, y: centerY))
            }

            // Determine transform values — use keyframe interpolation if available
            let animatedOffset: (x: CGFloat, y: CGFloat)
            let animatedScale: CGFloat
            let animatedRotation: CGFloat

            if !layerData.clipKeyframes.isEmpty {
                let interpolated = interpolateClipKeyframes(
                    keyframes: layerData.clipKeyframes,
                    compositionTime: request.compositionTime,
                    clipStart: layerData.clipStartTimeInTimeline,
                    clipDuration: layerData.clipTrimmedDuration
                )
                animatedOffset = (interpolated.offsetX, interpolated.offsetY)
                animatedScale = interpolated.scale
                animatedRotation = interpolated.rotation
            } else {
                animatedOffset = (layerData.offsetX, layerData.offsetY)
                animatedScale = layerData.scale
                animatedRotation = layerData.rotation
            }

            // Apply user scale + rotation (around center of render area)
            let cx = renderSize.width / 2
            let cy = renderSize.height / 2
            if animatedScale != 1.0 || animatedRotation != 0 {
                let radians = animatedRotation * .pi / 180.0
                let combinedTransform = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: animatedScale, y: animatedScale)
                    .rotated(by: radians)
                    .translatedBy(x: -cx, y: -cy)
                image = image.transformed(by: combinedTransform)
            }

            // Apply user offset (Y is flipped for Core Image)
            if animatedOffset.x != 0 || animatedOffset.y != 0 {
                image = image.transformed(
                    by: CGAffineTransform(translationX: animatedOffset.x, y: -animatedOffset.y)
                )
            }

            // Apply exposure via CIExposureAdjust
            if layerData.exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: layerData.exposure
                ])
            }

            // Apply named filter
            if let filterName = layerData.filter.ciFilterName {
                image = applyFilter(filterName, to: image, data: layerData)
            }

            // Crop to render bounds (filters like blur can expand extent)
            image = image.cropped(to: renderRect)

            // Composite over background
            composited = image.composited(over: composited)
        }

        // Draw text overlays with keyframe animation
        let currentTime = request.compositionTime
        for textOverlay in instruction.textOverlays {
            if CMTimeCompare(currentTime, textOverlay.startTime) >= 0 &&
               CMTimeCompare(currentTime, textOverlay.endTime) < 0 {
                let interpolated = textOverlay.interpolatedValues(at: currentTime)
                composited = drawText(textOverlay, interpolated: interpolated,
                                      on: composited, renderSize: renderSize)
            }
        }

        // Render to output pixel buffer
        var outputBuffer: CVPixelBuffer?
        if let rc = renderContext {
            outputBuffer = rc.newPixelBuffer()
        }

        // Fallback: create pixel buffer manually if renderContext didn't provide one
        if outputBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(renderSize.width), Int(renderSize.height),
                                kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &buffer)
            outputBuffer = buffer
        }

        guard let finalBuffer = outputBuffer else {
            request.finish(with: NSError(domain: "CustomCompositor", code: -2))
            return
        }

        ciContext.render(composited, to: finalBuffer)
        request.finish(withComposedVideoFrame: finalBuffer)
    }

    // MARK: - Clip Keyframe Interpolation

    private func interpolateClipKeyframes(
        keyframes: [ClipKeyframe],
        compositionTime: CMTime,
        clipStart: CMTime,
        clipDuration: CMTime
    ) -> InterpolatedClipValues {
        let duration = CMTimeGetSeconds(clipDuration)
        guard duration > 0 else {
            let kf = keyframes[0]
            return InterpolatedClipValues(
                offsetX: kf.offsetX, offsetY: kf.offsetY,
                scale: kf.scale, rotation: kf.rotation
            )
        }

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(compositionTime, clipStart))
        let normalizedT = CGFloat(max(0, min(elapsed / duration, 1.0)))

        let sorted = keyframes.sorted { $0.normalizedTime < $1.normalizedTime }

        if normalizedT <= sorted.first!.normalizedTime {
            let kf = sorted.first!
            return InterpolatedClipValues(
                offsetX: kf.offsetX, offsetY: kf.offsetY,
                scale: kf.scale, rotation: kf.rotation
            )
        }

        if normalizedT >= sorted.last!.normalizedTime {
            let kf = sorted.last!
            return InterpolatedClipValues(
                offsetX: kf.offsetX, offsetY: kf.offsetY,
                scale: kf.scale, rotation: kf.rotation
            )
        }

        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            if normalizedT >= a.normalizedTime && normalizedT <= b.normalizedTime {
                let segLen = b.normalizedTime - a.normalizedTime
                let segT = segLen > 0 ? (normalizedT - a.normalizedTime) / segLen : 0
                let valA = InterpolatedClipValues(
                    offsetX: a.offsetX, offsetY: a.offsetY,
                    scale: a.scale, rotation: a.rotation
                )
                let valB = InterpolatedClipValues(
                    offsetX: b.offsetX, offsetY: b.offsetY,
                    scale: b.scale, rotation: b.rotation
                )
                return InterpolatedClipValues.lerp(valA, valB, t: segT)
            }
        }

        let kf = sorted.last!
        return InterpolatedClipValues(
            offsetX: kf.offsetX, offsetY: kf.offsetY,
            scale: kf.scale, rotation: kf.rotation
        )
    }

    // MARK: - Filter Application

    private func applyFilter(_ name: String, to image: CIImage,
                             data: CustomCompositorInstruction.LayerRenderData) -> CIImage {
        var params: [String: Any] = [:]

        switch data.filter {
        case .sepia:
            params[kCIInputIntensityKey] = data.filterIntensity
        case .vignette:
            params[kCIInputIntensityKey] = data.filterIntensity * 2.0
            params[kCIInputRadiusKey] = 1.0
        case .bloom:
            params[kCIInputIntensityKey] = data.filterIntensity
            params[kCIInputRadiusKey] = 10.0
        case .gaussianBlur:
            params[kCIInputRadiusKey] = data.filterIntensity * 20.0
        case .sharpen:
            params[kCIInputSharpnessKey] = data.filterIntensity
        default:
            break
        }

        return image.applyingFilter(name, parameters: params)
    }

    // MARK: - Text Rendering

    private func drawText(_ overlay: TextOverlay, interpolated: InterpolatedTextValues,
                          on background: CIImage, renderSize: CGSize) -> CIImage {
        // Skip rendering if fully transparent
        guard interpolated.opacity > 0.001 else { return background }

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return background
        }

        ctx.clear(CGRect(origin: .zero, size: renderSize))

        let font = NSFont(name: overlay.fontName, size: overlay.fontSize)
            ?? NSFont.systemFont(ofSize: overlay.fontSize, weight: .bold)

        let nsColor = NSColor(
            red: overlay.colorRed,
            green: overlay.colorGreen,
            blue: overlay.colorBlue,
            alpha: overlay.colorAlpha
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor,
            .paragraphStyle: paragraphStyle
        ]

        let nsString = overlay.text as NSString
        let stringSize = nsString.size(withAttributes: attributes)

        // Use interpolated position (animated keyframe values)
        let centerX = interpolated.positionX * renderSize.width
        let centerY = (1.0 - interpolated.positionY) * renderSize.height

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsContext

        // Apply rotation and scale transforms around the text center point
        let transform = NSAffineTransform()
        transform.translateX(by: centerX, yBy: centerY)
        transform.rotate(byDegrees: interpolated.rotation)
        transform.scale(by: interpolated.scale)
        transform.translateX(by: -centerX, yBy: -centerY)
        transform.concat()

        let drawX = centerX - stringSize.width / 2
        let drawY = centerY - stringSize.height / 2
        nsString.draw(at: NSPoint(x: drawX, y: drawY), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return background }
        var textImage = CIImage(cgImage: cgImage)

        // Apply opacity via CIColorMatrix alpha scaling
        if interpolated.opacity < 0.999 {
            textImage = textImage.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: interpolated.opacity)
            ])
        }

        return textImage.composited(over: background)
    }
}
