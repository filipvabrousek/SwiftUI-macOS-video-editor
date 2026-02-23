import Foundation
import AVFoundation
import SwiftUI

// MARK: - Clip Keyframe

/// A keyframe for animating clip transform properties over time.
/// normalizedTime is 0...1 within the clip's trimmed duration.
struct ClipKeyframe: Identifiable, Equatable, Sendable {
    let id: UUID
    var normalizedTime: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
    var scale: CGFloat
    var rotation: CGFloat   // degrees

    init(
        normalizedTime: CGFloat = 0,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0,
        scale: CGFloat = 1.0,
        rotation: CGFloat = 0
    ) {
        self.id = UUID()
        self.normalizedTime = normalizedTime
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.rotation = rotation
    }
}

/// Interpolated clip transform values at a specific frame.
struct InterpolatedClipValues: Sendable {
    var offsetX: CGFloat
    var offsetY: CGFloat
    var scale: CGFloat
    var rotation: CGFloat

    static func lerp(_ a: InterpolatedClipValues, _ b: InterpolatedClipValues, t: CGFloat) -> InterpolatedClipValues {
        InterpolatedClipValues(
            offsetX: a.offsetX + (b.offsetX - a.offsetX) * t,
            offsetY: a.offsetY + (b.offsetY - a.offsetY) * t,
            scale: a.scale + (b.scale - a.scale) * t,
            rotation: a.rotation + (b.rotation - a.rotation) * t
        )
    }
}

// MARK: - Video Clip

struct VideoClip: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let originalDuration: CMTime
    var trimStart: CMTime
    var trimEnd: CMTime
    var exposure: Float
    var displayName: String
    var thumbnailImage: NSImage?

    // Transform
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scale: CGFloat = 1.0
    var rotation: CGFloat = 0  // degrees

    // Filter
    var filter: VideoFilter = .none
    var filterIntensity: Float = 1.0

    // Multi-track
    var track: Int = 0
    var startTimeInTimeline: CMTime = .zero

    // Cached from asset at import time
    var preferredTransform: CGAffineTransform = .identity

    // Keyframes for animating position, scale, rotation over clip duration
    var keyframes: [ClipKeyframe] = []

    var trimmedDuration: CMTime {
        CMTimeSubtract(trimEnd, trimStart)
    }

    var trimmedDurationSeconds: Double {
        CMTimeGetSeconds(trimmedDuration)
    }

    var hasTransformModifications: Bool {
        offsetX != 0 || offsetY != 0 || scale != 1.0 || rotation != 0
    }

    var hasKeyframes: Bool {
        !keyframes.isEmpty
    }

    init(
        sourceURL: URL,
        duration: CMTime,
        displayName: String,
        thumbnailImage: NSImage? = nil,
        preferredTransform: CGAffineTransform = .identity
    ) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.originalDuration = duration
        self.trimStart = .zero
        self.trimEnd = duration
        self.exposure = 0.0
        self.displayName = displayName
        self.thumbnailImage = thumbnailImage
        self.preferredTransform = preferredTransform
    }

    /// Interpolate clip transform values at a given composition time.
    /// If no keyframes, returns static offsetX/offsetY/scale/rotation.
    func interpolatedValues(at compositionTime: CMTime) -> InterpolatedClipValues {
        guard !keyframes.isEmpty else {
            return InterpolatedClipValues(
                offsetX: offsetX, offsetY: offsetY,
                scale: scale, rotation: rotation
            )
        }

        let duration = trimmedDurationSeconds
        guard duration > 0 else {
            let kf = keyframes[0]
            return InterpolatedClipValues(
                offsetX: kf.offsetX, offsetY: kf.offsetY,
                scale: kf.scale, rotation: kf.rotation
            )
        }

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(compositionTime, startTimeInTimeline))
        let normalizedT = CGFloat(max(0, min(elapsed / duration, 1.0)))

        let sorted = keyframes.sorted { $0.normalizedTime < $1.normalizedTime }

        // Before first keyframe — hold
        if normalizedT <= sorted.first!.normalizedTime {
            let kf = sorted.first!
            return InterpolatedClipValues(
                offsetX: kf.offsetX, offsetY: kf.offsetY,
                scale: kf.scale, rotation: kf.rotation
            )
        }

        // After last keyframe — hold
        if normalizedT >= sorted.last!.normalizedTime {
            let kf = sorted.last!
            return InterpolatedClipValues(
                offsetX: kf.offsetX, offsetY: kf.offsetY,
                scale: kf.scale, rotation: kf.rotation
            )
        }

        // Interpolate between surrounding keyframes
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
}

