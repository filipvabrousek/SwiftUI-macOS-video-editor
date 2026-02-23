import Foundation
import CoreMedia
import AppKit

// MARK: - Text Keyframe

/// A keyframe captures animatable text properties at a specific normalized time (0...1)
/// within the text overlay's duration. The compositor interpolates between keyframes.
struct TextKeyframe: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Normalized time within the overlay (0.0 = start, 1.0 = end)
    var normalizedTime: CGFloat
    /// Position X (0...1, normalized to render size)
    var positionX: CGFloat
    /// Position Y (0...1, normalized to render size)
    var positionY: CGFloat
    /// Rotation in degrees
    var rotation: CGFloat
    /// Scale factor (1.0 = 100%)
    var scale: CGFloat
    /// Opacity (0...1)
    var opacity: CGFloat

    init(
        normalizedTime: CGFloat = 0,
        positionX: CGFloat = 0.5,
        positionY: CGFloat = 0.5,
        rotation: CGFloat = 0,
        scale: CGFloat = 1.0,
        opacity: CGFloat = 1.0
    ) {
        self.id = UUID()
        self.normalizedTime = normalizedTime
        self.positionX = positionX
        self.positionY = positionY
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
    }
}

/// Interpolated values at a specific frame time — produced by the keyframe engine,
/// consumed by the compositor's text renderer.
struct InterpolatedTextValues: Sendable {
    var positionX: CGFloat
    var positionY: CGFloat
    var rotation: CGFloat
    var scale: CGFloat
    var opacity: CGFloat

    /// Linearly interpolate between two sets of values.
    static func lerp(_ a: InterpolatedTextValues, _ b: InterpolatedTextValues, t: CGFloat) -> InterpolatedTextValues {
        InterpolatedTextValues(
            positionX: a.positionX + (b.positionX - a.positionX) * t,
            positionY: a.positionY + (b.positionY - a.positionY) * t,
            rotation: a.rotation + (b.rotation - a.rotation) * t,
            scale: a.scale + (b.scale - a.scale) * t,
            opacity: a.opacity + (b.opacity - a.opacity) * t
        )
    }
}

// MARK: - Text Overlay

struct TextOverlay: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var colorRed: CGFloat
    var colorGreen: CGFloat
    var colorBlue: CGFloat
    var colorAlpha: CGFloat
    var positionX: CGFloat
    var positionY: CGFloat
    var startTime: CMTime
    var endTime: CMTime

    /// Keyframes for animating position, rotation, scale, and opacity.
    /// Sorted by normalizedTime. If empty, uses static positionX/positionY with no animation.
    var keyframes: [TextKeyframe]

    var nsColor: NSColor {
        NSColor(red: colorRed, green: colorGreen, blue: colorBlue, alpha: colorAlpha)
    }

    var cgColor: CGColor {
        CGColor(red: colorRed, green: colorGreen, blue: colorBlue, alpha: colorAlpha)
    }

    var durationSeconds: Double {
        CMTimeGetSeconds(CMTimeSubtract(endTime, startTime))
    }

    init(
        text: String = "Text",
        fontName: String = "Helvetica-Bold",
        fontSize: CGFloat = 48,
        colorRed: CGFloat = 1,
        colorGreen: CGFloat = 1,
        colorBlue: CGFloat = 1,
        colorAlpha: CGFloat = 1,
        positionX: CGFloat = 0.5,
        positionY: CGFloat = 0.5,
        startTime: CMTime = .zero,
        endTime: CMTime = CMTimeMake(value: 5, timescale: 1)
    ) {
        self.id = UUID()
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorRed = colorRed
        self.colorGreen = colorGreen
        self.colorBlue = colorBlue
        self.colorAlpha = colorAlpha
        self.positionX = positionX
        self.positionY = positionY
        self.startTime = startTime
        self.endTime = endTime
        self.keyframes = []
    }

    /// Interpolate animated values at the given composition time.
    /// If no keyframes exist, returns static values from positionX/positionY.
    func interpolatedValues(at compositionTime: CMTime) -> InterpolatedTextValues {
        guard !keyframes.isEmpty else {
            return InterpolatedTextValues(
                positionX: positionX,
                positionY: positionY,
                rotation: 0,
                scale: 1.0,
                opacity: 1.0
            )
        }

        let duration = durationSeconds
        guard duration > 0 else {
            let kf = keyframes[0]
            return InterpolatedTextValues(
                positionX: kf.positionX,
                positionY: kf.positionY,
                rotation: kf.rotation,
                scale: kf.scale,
                opacity: kf.opacity
            )
        }

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(compositionTime, startTime))
        let normalizedT = CGFloat(max(0, min(elapsed / duration, 1.0)))

        let sorted = keyframes.sorted { $0.normalizedTime < $1.normalizedTime }

        // Before first keyframe — hold first keyframe values
        if normalizedT <= sorted.first!.normalizedTime {
            let kf = sorted.first!
            return InterpolatedTextValues(
                positionX: kf.positionX,
                positionY: kf.positionY,
                rotation: kf.rotation,
                scale: kf.scale,
                opacity: kf.opacity
            )
        }

        // After last keyframe — hold last keyframe values
        if normalizedT >= sorted.last!.normalizedTime {
            let kf = sorted.last!
            return InterpolatedTextValues(
                positionX: kf.positionX,
                positionY: kf.positionY,
                rotation: kf.rotation,
                scale: kf.scale,
                opacity: kf.opacity
            )
        }

        // Find the two keyframes to interpolate between
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]

            if normalizedT >= a.normalizedTime && normalizedT <= b.normalizedTime {
                let segmentLength = b.normalizedTime - a.normalizedTime
                let segmentT = segmentLength > 0 ? (normalizedT - a.normalizedTime) / segmentLength : 0

                let valA = InterpolatedTextValues(
                    positionX: a.positionX,
                    positionY: a.positionY,
                    rotation: a.rotation,
                    scale: a.scale,
                    opacity: a.opacity
                )
                let valB = InterpolatedTextValues(
                    positionX: b.positionX,
                    positionY: b.positionY,
                    rotation: b.rotation,
                    scale: b.scale,
                    opacity: b.opacity
                )
                return InterpolatedTextValues.lerp(valA, valB, t: segmentT)
            }
        }

        // Fallback
        let kf = sorted.last!
        return InterpolatedTextValues(
            positionX: kf.positionX,
            positionY: kf.positionY,
            rotation: kf.rotation,
            scale: kf.scale,
            opacity: kf.opacity
        )
    }
}
