import Foundation
import AVFoundation
import SwiftUI
import Combine

struct ClipPlacement {
    let clip: VideoClip
    let trackID: CMPersistentTrackID
    let compositionTimeRange: CMTimeRange
}

@Observable
final class EditorViewModel {
    var clips: [VideoClip] = []
    var textOverlays: [TextOverlay] = []
    var selectedClipID: UUID?
    var selectedTextOverlayID: UUID?
    var selectedKeyframeID: UUID?
    var isPlaying = false
    var currentTime: Double = 0
    var isExporting = false
    var exportProgress: Double = 0
    var errorMessage: String?
    var showError = false

    var player: AVPlayer?
    var playerComposition: AVMutableComposition?
    var playerVideoComposition: AVMutableVideoComposition?

    private var timeObserverToken: Any?
    private var isRebuilding = false

    var selectedClip: VideoClip? {
        guard let id = selectedClipID else { return nil }
        return clips.first { $0.id == id }
    }

    var selectedClipIndex: Int? {
        guard let id = selectedClipID else { return nil }
        return clips.firstIndex { $0.id == id }
    }

    var selectedTextOverlay: TextOverlay? {
        guard let id = selectedTextOverlayID else { return nil }
        return textOverlays.first { $0.id == id }
    }

    var mainTrackClips: [VideoClip] {
        clips.filter { $0.track == 0 }.sorted {
            CMTimeCompare($0.startTimeInTimeline, $1.startTimeInTimeline) < 0
        }
    }

    var totalDuration: Double {
        var maxEnd: Double = 0
        for clip in clips {
            let clipEnd = CMTimeGetSeconds(clip.startTimeInTimeline) + clip.trimmedDurationSeconds
            maxEnd = max(maxEnd, clipEnd)
        }
        for overlay in textOverlays {
            maxEnd = max(maxEnd, CMTimeGetSeconds(overlay.endTime))
        }
        return maxEnd
    }

    var trackCount: Int {
        max((clips.map(\.track).max() ?? 0) + 1, 1)
    }

    func overlayClips(forTrack track: Int) -> [VideoClip] {
        clips.filter { $0.track == track }
    }

    // MARK: - Clip Management

    func importClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select video files to import"

        guard panel.runModal() == .OK else { return }

        Task {
            for url in panel.urls {
                await loadClip(from: url)
            }
        }
    }

    private func loadClip(from url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let thumbnail = await generateThumbnail(for: asset)
            let name = url.deletingPathExtension().lastPathComponent

            // Cache preferred transform using async API
            var transform = CGAffineTransform.identity
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                transform = try await videoTrack.load(.preferredTransform)
            }

            var clip = VideoClip(
                sourceURL: url,
                duration: duration,
                displayName: name,
                thumbnailImage: thumbnail,
                preferredTransform: transform
            )

            // Place new clip at the end of the current timeline
            let endOfTimeline = totalDuration
            clip.startTimeInTimeline = CMTimeMakeWithSeconds(endOfTimeline, preferredTimescale: 600)

            clips.append(clip)

            if selectedClipID == nil {
                selectedClipID = clip.id
            }

            rebuildPlayerComposition()
        } catch {
            errorMessage = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
            showError = true
        }
    }

    private func generateThumbnail(for asset: AVAsset) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)

        do {
            let (image, _) = try await generator.image(at: .zero)
            return NSImage(cgImage: image, size: NSSize(width: 160, height: 90))
        } catch {
            return nil
        }
    }

    func removeClip(_ id: UUID) {
        clips.removeAll { $0.id == id }
        if selectedClipID == id {
            selectedClipID = clips.first?.id
        }
        rebuildPlayerComposition()
    }

    // MARK: - Split (Cut) at Playhead

    /// Splits the clip under the playhead into two clips at the current time.
    /// All clips use startTimeInTimeline for absolute positioning.
    func splitClipAtPlayhead() {
        let playheadTime = currentTime

        // Find the clip under the playhead (all clips use startTimeInTimeline)
        for (arrayIndex, clip) in clips.enumerated() {
            let clipStart = CMTimeGetSeconds(clip.startTimeInTimeline)
            let clipEnd = clipStart + clip.trimmedDurationSeconds

            if playheadTime > clipStart + 0.03 && playheadTime < clipEnd - 0.03 {
                performSplit(arrayIndex: arrayIndex, clip: clip,
                             localOffset: playheadTime - clipStart)
                return
            }
        }
    }

    private func performSplit(arrayIndex: Int, clip: VideoClip, localOffset: Double) {
        // The split point in the source media
        let splitSourceTime = CMTimeAdd(clip.trimStart,
                                        CMTimeMakeWithSeconds(localOffset, preferredTimescale: 600))

        // First half: keeps the original id, trimEnd moves to split point
        var firstHalf = clip
        firstHalf.trimEnd = splitSourceTime
        firstHalf.startTimeInTimeline = clip.startTimeInTimeline

        // Second half: new clip from same source, trimStart at split point
        var secondHalf = VideoClip(
            sourceURL: clip.sourceURL,
            duration: clip.originalDuration,
            displayName: clip.displayName,
            thumbnailImage: clip.thumbnailImage,
            preferredTransform: clip.preferredTransform
        )
        secondHalf.trimStart = splitSourceTime
        secondHalf.trimEnd = clip.trimEnd
        secondHalf.exposure = clip.exposure
        secondHalf.offsetX = clip.offsetX
        secondHalf.offsetY = clip.offsetY
        secondHalf.scale = clip.scale
        secondHalf.rotation = clip.rotation
        secondHalf.filter = clip.filter
        secondHalf.filterIntensity = clip.filterIntensity
        secondHalf.track = clip.track

        // Position second half right after first
        let firstHalfEnd = CMTimeGetSeconds(clip.startTimeInTimeline) + localOffset
        secondHalf.startTimeInTimeline = CMTimeMakeWithSeconds(firstHalfEnd, preferredTimescale: 600)

        // Replace the original clip with the two halves
        clips[arrayIndex] = firstHalf
        clips.insert(secondHalf, at: arrayIndex + 1)

        // Select the second half
        selectedClipID = secondHalf.id

        rebuildPlayerComposition()
    }

    // MARK: - Trim

    func updateTrimStart(_ clipID: UUID, seconds: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let newStart = CMTimeMakeWithSeconds(max(0, seconds), preferredTimescale: 600)
        if CMTimeCompare(newStart, clips[index].trimEnd) < 0 {
            clips[index].trimStart = newStart
            rebuildPlayerComposition()
        }
    }

    func updateTrimEnd(_ clipID: UUID, seconds: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let maxEnd = CMTimeGetSeconds(clips[index].originalDuration)
        let newEnd = CMTimeMakeWithSeconds(min(seconds, maxEnd), preferredTimescale: 600)
        if CMTimeCompare(clips[index].trimStart, newEnd) < 0 {
            clips[index].trimEnd = newEnd
            rebuildPlayerComposition()
        }
    }

    // MARK: - Exposure

    func updateExposure(_ clipID: UUID, value: Float) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].exposure = value
        rebuildPlayerComposition()
    }

    // MARK: - Transform

    func updateOffset(_ clipID: UUID, x: CGFloat, y: CGFloat) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].offsetX = x
        clips[index].offsetY = y
        rebuildPlayerComposition()
    }

    func updateOffsetX(_ clipID: UUID, value: CGFloat) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].offsetX = value
        rebuildPlayerComposition()
    }

    func updateOffsetY(_ clipID: UUID, value: CGFloat) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].offsetY = value
        rebuildPlayerComposition()
    }

    func updateScale(_ clipID: UUID, value: CGFloat) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].scale = value
        rebuildPlayerComposition()
    }

    func updateRotation(_ clipID: UUID, value: CGFloat) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].rotation = value
        rebuildPlayerComposition()
    }

    // MARK: - Clip Keyframes

    var selectedClipKeyframeID: UUID?

    func addClipKeyframe(to clipID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clips[index]

        let clipStart = CMTimeGetSeconds(clip.startTimeInTimeline)
        let clipDuration = clip.trimmedDurationSeconds
        var normalizedTime: CGFloat = 0.5

        if clipDuration > 0 {
            let elapsed = currentTime - clipStart
            normalizedTime = CGFloat(max(0, min(elapsed / clipDuration, 1.0)))
        }

        // Don't add duplicate at same time
        let threshold: CGFloat = 0.02
        if clip.keyframes.contains(where: { abs($0.normalizedTime - normalizedTime) < threshold }) {
            return
        }

        // Interpolate current values as defaults
        let interpolated = clip.interpolatedValues(
            at: CMTimeMakeWithSeconds(currentTime, preferredTimescale: 600)
        )

        let kf = ClipKeyframe(
            normalizedTime: normalizedTime,
            offsetX: clip.keyframes.isEmpty ? clip.offsetX : interpolated.offsetX,
            offsetY: clip.keyframes.isEmpty ? clip.offsetY : interpolated.offsetY,
            scale: clip.keyframes.isEmpty ? clip.scale : interpolated.scale,
            rotation: clip.keyframes.isEmpty ? clip.rotation : interpolated.rotation
        )

        clips[index].keyframes.append(kf)
        clips[index].keyframes.sort { $0.normalizedTime < $1.normalizedTime }
        selectedClipKeyframeID = kf.id
        rebuildPlayerComposition()
    }

    func removeClipKeyframe(_ keyframeID: UUID, from clipID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].keyframes.removeAll { $0.id == keyframeID }
        if selectedClipKeyframeID == keyframeID {
            selectedClipKeyframeID = nil
        }
        rebuildPlayerComposition()
    }

    func updateClipKeyframe(_ keyframeID: UUID, in clipID: UUID,
                             offsetX: CGFloat? = nil, offsetY: CGFloat? = nil,
                             scale: CGFloat? = nil, rotation: CGFloat? = nil,
                             normalizedTime: CGFloat? = nil) {
        guard let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
              let kfIndex = clips[clipIndex].keyframes.firstIndex(where: { $0.id == keyframeID })
        else { return }

        if let v = offsetX { clips[clipIndex].keyframes[kfIndex].offsetX = v }
        if let v = offsetY { clips[clipIndex].keyframes[kfIndex].offsetY = v }
        if let v = scale { clips[clipIndex].keyframes[kfIndex].scale = v }
        if let v = rotation { clips[clipIndex].keyframes[kfIndex].rotation = v }
        if let v = normalizedTime {
            clips[clipIndex].keyframes[kfIndex].normalizedTime = max(0, min(v, 1))
            clips[clipIndex].keyframes.sort { $0.normalizedTime < $1.normalizedTime }
        }

        rebuildPlayerComposition()
    }

    func clearAllClipKeyframes(from clipID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].keyframes.removeAll()
        selectedClipKeyframeID = nil
        rebuildPlayerComposition()
    }

    // MARK: - Filter

    func updateFilter(_ clipID: UUID, filter: VideoFilter) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].filter = filter
        rebuildPlayerComposition()
    }

    func updateFilterIntensity(_ clipID: UUID, value: Float) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].filterIntensity = value
        rebuildPlayerComposition()
    }

    // MARK: - Multi-Track

    func moveClipToTrack(_ clipID: UUID, track: Int) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].track = track
        rebuildPlayerComposition()
    }

    func updateClipStartTimeInTimeline(_ clipID: UUID, seconds: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].startTimeInTimeline = CMTimeMakeWithSeconds(max(0, seconds), preferredTimescale: 600)
        rebuildPlayerComposition()
    }

    /// Move clip position without rebuilding — used during drag for responsive UI.
    /// Call rebuildPlayerComposition() when the drag ends.
    func moveClipPosition(_ clipID: UUID, seconds: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].startTimeInTimeline = CMTimeMakeWithSeconds(max(0, seconds), preferredTimescale: 600)
    }

    func addOverlayTrack() {
        // No-op: tracks are created implicitly when a clip is moved to a new track index
    }

    // MARK: - Text Overlays

    func addTextOverlay() {
        let startTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 600)
        let endTime = CMTimeMakeWithSeconds(min(currentTime + 3, totalDuration), preferredTimescale: 600)
        let overlay = TextOverlay(startTime: startTime, endTime: endTime)
        textOverlays.append(overlay)
        selectedTextOverlayID = overlay.id
        rebuildPlayerComposition()
    }

    func removeTextOverlay(_ id: UUID) {
        textOverlays.removeAll { $0.id == id }
        if selectedTextOverlayID == id {
            selectedTextOverlayID = nil
            selectedKeyframeID = nil
        }
        rebuildPlayerComposition()
    }

    func updateTextOverlayText(_ id: UUID, text: String) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        textOverlays[index].text = text
        rebuildPlayerComposition()
    }

    func updateTextOverlayFont(_ id: UUID, fontName: String) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        textOverlays[index].fontName = fontName
        rebuildPlayerComposition()
    }

    func updateTextOverlayFontSize(_ id: UUID, size: CGFloat) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        textOverlays[index].fontSize = size
        rebuildPlayerComposition()
    }

    func updateTextOverlayColor(_ id: UUID, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        textOverlays[index].colorRed = red
        textOverlays[index].colorGreen = green
        textOverlays[index].colorBlue = blue
        textOverlays[index].colorAlpha = alpha
        rebuildPlayerComposition()
    }

    func updateTextOverlayPosition(_ id: UUID, x: CGFloat, y: CGFloat) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        textOverlays[index].positionX = x
        textOverlays[index].positionY = y
        rebuildPlayerComposition()
    }

    func updateTextOverlayTiming(_ id: UUID, startSeconds: Double, endSeconds: Double) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        textOverlays[index].startTime = CMTimeMakeWithSeconds(max(0, startSeconds), preferredTimescale: 600)
        textOverlays[index].endTime = CMTimeMakeWithSeconds(max(startSeconds + 0.1, endSeconds), preferredTimescale: 600)
        rebuildPlayerComposition()
    }

    // MARK: - Text Overlay Keyframes

    func addKeyframe(to overlayID: UUID) {
        guard let index = textOverlays.firstIndex(where: { $0.id == overlayID }) else { return }
        let overlay = textOverlays[index]

        // Determine the normalized time for the new keyframe based on the playhead position
        let overlayStart = CMTimeGetSeconds(overlay.startTime)
        let overlayDuration = overlay.durationSeconds
        var normalizedTime: CGFloat = 0.5

        if overlayDuration > 0 {
            let elapsed = currentTime - overlayStart
            normalizedTime = CGFloat(max(0, min(elapsed / overlayDuration, 1.0)))
        }

        // If a keyframe already exists very close to this time, don't add a duplicate
        let threshold: CGFloat = 0.02
        if overlay.keyframes.contains(where: { abs($0.normalizedTime - normalizedTime) < threshold }) {
            return
        }

        // Interpolate current values at this time to use as defaults
        let interpolated = overlay.interpolatedValues(
            at: CMTimeMakeWithSeconds(currentTime, preferredTimescale: 600)
        )

        let keyframe = TextKeyframe(
            normalizedTime: normalizedTime,
            positionX: overlay.keyframes.isEmpty ? overlay.positionX : interpolated.positionX,
            positionY: overlay.keyframes.isEmpty ? overlay.positionY : interpolated.positionY,
            rotation: interpolated.rotation,
            scale: interpolated.scale,
            opacity: interpolated.opacity
        )

        textOverlays[index].keyframes.append(keyframe)
        textOverlays[index].keyframes.sort { $0.normalizedTime < $1.normalizedTime }
        rebuildPlayerComposition()
    }

    func removeKeyframe(_ keyframeID: UUID, from overlayID: UUID) {
        guard let index = textOverlays.firstIndex(where: { $0.id == overlayID }) else { return }
        textOverlays[index].keyframes.removeAll { $0.id == keyframeID }
        rebuildPlayerComposition()
    }

    func updateKeyframe(_ keyframeID: UUID, in overlayID: UUID,
                         positionX: CGFloat? = nil, positionY: CGFloat? = nil,
                         rotation: CGFloat? = nil, scale: CGFloat? = nil,
                         opacity: CGFloat? = nil, normalizedTime: CGFloat? = nil) {
        guard let overlayIndex = textOverlays.firstIndex(where: { $0.id == overlayID }),
              let kfIndex = textOverlays[overlayIndex].keyframes.firstIndex(where: { $0.id == keyframeID })
        else { return }

        if let v = positionX { textOverlays[overlayIndex].keyframes[kfIndex].positionX = v }
        if let v = positionY { textOverlays[overlayIndex].keyframes[kfIndex].positionY = v }
        if let v = rotation { textOverlays[overlayIndex].keyframes[kfIndex].rotation = v }
        if let v = scale { textOverlays[overlayIndex].keyframes[kfIndex].scale = v }
        if let v = opacity { textOverlays[overlayIndex].keyframes[kfIndex].opacity = v }
        if let v = normalizedTime {
            textOverlays[overlayIndex].keyframes[kfIndex].normalizedTime = max(0, min(v, 1))
            textOverlays[overlayIndex].keyframes.sort { $0.normalizedTime < $1.normalizedTime }
        }

        rebuildPlayerComposition()
    }

    func clearAllKeyframes(from overlayID: UUID) {
        guard let index = textOverlays.firstIndex(where: { $0.id == overlayID }) else { return }
        textOverlays[index].keyframes.removeAll()
        rebuildPlayerComposition()
    }

    /// Move text overlay position without rebuilding — used during drag.
    /// Call rebuildPlayerComposition() when the drag ends.
    func moveTextOverlayPosition(_ id: UUID, startSeconds: Double) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        let duration = textOverlays[index].durationSeconds
        let newStart = max(0, startSeconds)
        textOverlays[index].startTime = CMTimeMakeWithSeconds(newStart, preferredTimescale: 600)
        textOverlays[index].endTime = CMTimeMakeWithSeconds(newStart + duration, preferredTimescale: 600)
    }

    // MARK: - Composition Pipeline

    func rebuildPlayerComposition() {
        Task { @MainActor in
            await rebuildPlayerCompositionAsync()
        }
    }

    private func rebuildPlayerCompositionAsync() async {
        // Capture playhead position IMMEDIATELY, before any async work
        let savedTime = currentTime
        let wasPlaying = isPlaying
        isRebuilding = true

        guard !clips.isEmpty else {
            player?.pause()
            player = nil
            playerComposition = nil
            playerVideoComposition = nil
            isPlaying = false
            isRebuilding = false
            return
        }

        guard let (composition, videoComposition) = await buildCompositionPair() else {
            isRebuilding = false
            return
        }

        playerComposition = composition
        playerVideoComposition = videoComposition

        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = videoComposition

        if let existingPlayer = player {
            existingPlayer.pause()
            existingPlayer.replaceCurrentItem(with: playerItem)
        } else {
            player = AVPlayer(playerItem: playerItem)
            setupTimeObserver()
        }

        // Seek back to where the playhead was before rebuild started
        let seekTime = CMTimeMakeWithSeconds(savedTime, preferredTimescale: 600)
        await player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = savedTime
        isRebuilding = false

        if wasPlaying {
            player?.play()
        }
    }

    private func buildInstructions(placements: [ClipPlacement],
                                    compositionDuration: CMTime? = nil) -> [CustomCompositorInstruction] {
        guard !placements.isEmpty else { return [] }

        let timescale: CMTimeScale = 600

        // Use the actual composition duration if provided (important for export),
        // otherwise fall back to our computed totalDuration (for player preview).
        let effectiveEnd: CMTime
        if let compDur = compositionDuration {
            effectiveEnd = compDur
        } else {
            effectiveEnd = CMTimeMakeWithSeconds(totalDuration, preferredTimescale: timescale)
        }

        // Collect all time boundaries — include 0 and composition end
        var boundarySet: Set<Int64> = [0]
        boundarySet.insert(effectiveEnd.convertScale(timescale, method: .default).value)

        for p in placements {
            let startTicks = p.compositionTimeRange.start.convertScale(timescale, method: .default).value
            let endTime = CMTimeAdd(p.compositionTimeRange.start, p.compositionTimeRange.duration)
            let endTicks = endTime.convertScale(timescale, method: .default).value
            boundarySet.insert(startTicks)
            boundarySet.insert(endTicks)
        }

        // Clamp all boundaries to [0, effectiveEnd]
        let endTicks = effectiveEnd.convertScale(timescale, method: .default).value
        let clampedTicks = boundarySet.map { max(0, min($0, endTicks)) }
        let sortedTicks = Array(Set(clampedTicks)).sorted()
        guard sortedTicks.count >= 2 else { return [] }

        var instructions: [CustomCompositorInstruction] = []

        for i in 0..<(sortedTicks.count - 1) {
            let segStart = CMTimeMake(value: sortedTicks[i], timescale: timescale)
            let segEnd = CMTimeMake(value: sortedTicks[i + 1], timescale: timescale)
            let segDuration = CMTimeSubtract(segEnd, segStart)

            guard CMTimeGetSeconds(segDuration) > 0 else { continue }

            let segRange = CMTimeRange(start: segStart, duration: segDuration)

            // Find all clips active during this segment
            var layerData: [CMPersistentTrackID: CustomCompositorInstruction.LayerRenderData] = [:]
            var sourceTrackIDs: [CMPersistentTrackID] = []

            for p in placements {
                let clipStart = p.compositionTimeRange.start
                let clipEnd = CMTimeAdd(clipStart, p.compositionTimeRange.duration)

                let overlapStart = max(CMTimeGetSeconds(segStart), CMTimeGetSeconds(clipStart))
                let overlapEnd = min(CMTimeGetSeconds(segEnd), CMTimeGetSeconds(clipEnd))

                if overlapEnd > overlapStart {
                    layerData[p.trackID] = CustomCompositorInstruction.LayerRenderData(
                        trackID: p.trackID,
                        transform: p.clip.preferredTransform,
                        offsetX: p.clip.offsetX,
                        offsetY: p.clip.offsetY,
                        scale: p.clip.scale,
                        rotation: p.clip.rotation,
                        exposure: p.clip.exposure,
                        filter: p.clip.filter,
                        filterIntensity: p.clip.filterIntensity,
                        zOrder: p.clip.track,
                        clipKeyframes: p.clip.keyframes,
                        clipStartTimeInTimeline: p.clip.startTimeInTimeline,
                        clipTrimmedDuration: p.clip.trimmedDuration
                    )
                    sourceTrackIDs.append(p.trackID)
                }
            }

            // Filter text overlays active during this segment
            let activeTexts = textOverlays.filter { overlay in
                CMTimeCompare(overlay.startTime, segEnd) < 0 &&
                CMTimeCompare(overlay.endTime, segStart) > 0
            }

            // Always create an instruction — even for gaps (empty sourceTrackIDs
            // will render a black frame, possibly with text overlays).
            let instruction = CustomCompositorInstruction(
                timeRange: segRange,
                sourceTrackIDs: sourceTrackIDs,
                layerRenderData: layerData,
                textOverlays: activeTexts
            )
            instructions.append(instruction)
        }

        return instructions
    }

    private func determineRenderSizeAsync() async -> CGSize {
        guard let firstClip = clips.first else {
            return CGSize(width: 1920, height: 1080)
        }

        let asset = AVURLAsset(url: firstClip.sourceURL)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                return CGSize(width: 1920, height: 1080)
            }

            let size = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let isPortrait = transform.a == 0 && abs(transform.b) == 1

            return isPortrait
                ? CGSize(width: size.height, height: size.width)
                : size
        } catch {
            return CGSize(width: 1920, height: 1080)
        }
    }

    private func setupTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        let interval = CMTimeMakeWithSeconds(1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isRebuilding else { return }
            self.currentTime = CMTimeGetSeconds(time)
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= totalDuration {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: - Export

    func exportVideo() {
        guard !clips.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Exported Video.mp4"
        panel.message = "Choose where to save your exported video"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        try? FileManager.default.removeItem(at: outputURL)

        isExporting = true
        exportProgress = 0

        Task {
            await performExport(to: outputURL)
        }
    }

    /// Simple export: reads raw frames per-clip using AVAssetImageGenerator,
    /// composites them manually with CIImage (same logic as the compositor),
    /// and writes to an MP4 via AVAssetWriter. No AVAssetExportSession or
    /// Builds a fresh AVMutableComposition + AVMutableVideoComposition pair.
    /// Used by the player rebuild to create an independent composition.
    private func buildCompositionPair() async -> (AVMutableComposition, AVMutableVideoComposition)? {
        guard !clips.isEmpty else { return nil }

        let composition = AVMutableComposition()

        let clipsByTrack = Dictionary(grouping: clips, by: { $0.track })
        let trackIndices = clipsByTrack.keys.sorted()

        var compositionVideoTracks: [Int: AVMutableCompositionTrack] = [:]
        var compositionAudioTracks: [Int: AVMutableCompositionTrack] = [:]

        for trackIndex in trackIndices {
            if let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                compositionVideoTracks[trackIndex] = videoTrack
            }
            if let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                compositionAudioTracks[trackIndex] = audioTrack
            }
        }

        var clipPlacements: [ClipPlacement] = []

        for trackIndex in trackIndices {
            guard let trackClips = clipsByTrack[trackIndex],
                  let compVideoTrack = compositionVideoTracks[trackIndex] else { continue }
            let compAudioTrack = compositionAudioTracks[trackIndex]

            let sorted = trackClips.sorted {
                CMTimeCompare($0.startTimeInTimeline, $1.startTimeInTimeline) < 0
            }

            var cursor = CMTime.zero

            for clip in sorted {
                let clipStart = clip.startTimeInTimeline

                if CMTimeCompare(clipStart, cursor) > 0 {
                    let gapDuration = CMTimeSubtract(clipStart, cursor)
                    let gapRange = CMTimeRange(start: cursor, duration: gapDuration)
                    compVideoTrack.insertEmptyTimeRange(gapRange)
                    compAudioTrack?.insertEmptyTimeRange(gapRange)
                    cursor = clipStart
                }

                let asset = AVURLAsset(url: clip.sourceURL)
                let sourceRange = CMTimeRange(start: clip.trimStart, duration: clip.trimmedDuration)

                do {
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    if let assetVideo = videoTracks.first {
                        try compVideoTrack.insertTimeRange(sourceRange, of: assetVideo, at: cursor)
                    }
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    if let assetAudio = audioTracks.first,
                       let compAudio = compAudioTrack {
                        try compAudio.insertTimeRange(sourceRange, of: assetAudio, at: cursor)
                    }
                } catch { continue }

                let compositionRange = CMTimeRange(start: cursor, duration: clip.trimmedDuration)
                clipPlacements.append(ClipPlacement(
                    clip: clip,
                    trackID: compVideoTrack.trackID,
                    compositionTimeRange: compositionRange
                ))

                cursor = CMTimeAdd(cursor, clip.trimmedDuration)
            }
        }

        let instructions = buildInstructions(placements: clipPlacements,
                                              compositionDuration: composition.duration)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CustomVideoCompositor.self
        videoComposition.instructions = instructions
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: 30)
        videoComposition.renderSize = await determineRenderSizeAsync()

        return (composition, videoComposition)
    }

    /// Renders every frame manually using AVAssetImageGenerator + CIImage compositing,
    /// then writes to MP4 via AVAssetWriter. No custom compositor needed for export.
    private func performExport(to outputURL: URL) async {
        let renderSize = await determineRenderSizeAsync()
        let fps: Int32 = 30
        let frameDuration = CMTimeMake(value: 1, timescale: fps)
        let totalFrames = Int(ceil(totalDuration * Double(fps)))

        guard totalFrames > 0 else {
            errorMessage = "Nothing to export"
            showError = true
            isExporting = false
            return
        }

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(renderSize.width),
                AVVideoHeightKey: Int(renderSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(renderSize.width * renderSize.height * 8),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false

            let pixelAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: pixelAttrs
            )
            writer.add(videoInput)

            // Audio composition for export
            let audioComposition = AVMutableComposition()
            var hasAudio = false
            let clipsByTrack = Dictionary(grouping: clips, by: { $0.track })
            for trackIndex in clipsByTrack.keys.sorted() {
                guard let trackClips = clipsByTrack[trackIndex] else { continue }
                let compAudioTrack = audioComposition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                let sorted = trackClips.sorted {
                    CMTimeCompare($0.startTimeInTimeline, $1.startTimeInTimeline) < 0
                }
                var cursor = CMTime.zero
                for clip in sorted {
                    let clipStart = clip.startTimeInTimeline
                    if CMTimeCompare(clipStart, cursor) > 0 {
                        compAudioTrack?.insertEmptyTimeRange(
                            CMTimeRange(start: cursor, duration: CMTimeSubtract(clipStart, cursor)))
                        cursor = clipStart
                    }
                    let asset = AVURLAsset(url: clip.sourceURL)
                    let sourceRange = CMTimeRange(start: clip.trimStart, duration: clip.trimmedDuration)
                    do {
                        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                        if let assetAudio = audioTracks.first, let compAudio = compAudioTrack {
                            try compAudio.insertTimeRange(sourceRange, of: assetAudio, at: cursor)
                            hasAudio = true
                        }
                    } catch {}
                    cursor = CMTimeAdd(cursor, clip.trimmedDuration)
                }
            }

            var audioInput: AVAssetWriterInput?
            var audioReader: AVAssetReader?
            var audioReaderOutput: AVAssetReaderAudioMixOutput?

            if hasAudio {
                let aReader = try AVAssetReader(asset: audioComposition)
                let aTracks = audioComposition.tracks(withMediaType: .audio)
                let aOutput = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: nil)
                if aReader.canAdd(aOutput) {
                    aReader.add(aOutput)
                    let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 128000
                    ])
                    aInput.expectsMediaDataInRealTime = false
                    if writer.canAdd(aInput) {
                        writer.add(aInput)
                        audioInput = aInput
                        audioReader = aReader
                        audioReaderOutput = aOutput
                    }
                }
            }

            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            audioReader?.startReading()

            let ciContext = CIContext(options: [.useSoftwareRenderer: false])
            let renderRect = CGRect(origin: .zero, size: renderSize)

            // Generate and write video frames on a background thread
            let clipsSnapshot = clips
            let overlaysSnapshot = textOverlays

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    for frameIndex in 0..<totalFrames {
                        // Wait for writer to be ready
                        while !videoInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.01)
                        }

                        let time = CMTimeMake(value: Int64(frameIndex), timescale: fps)
                        let seconds = CMTimeGetSeconds(time)

                        // Composite all active clips at this time
                        var composited = CIImage(color: .black).cropped(to: renderRect)

                        // Sort clips by track (z-order)
                        let sortedClips = clipsSnapshot.sorted { $0.track < $1.track }

                        for clip in sortedClips {
                            let clipStart = CMTimeGetSeconds(clip.startTimeInTimeline)
                            let clipEnd = clipStart + clip.trimmedDurationSeconds

                            guard seconds >= clipStart && seconds < clipEnd else { continue }

                            // Time in source media
                            let localTime = seconds - clipStart
                            let sourceTime = CMTimeAdd(clip.trimStart,
                                                       CMTimeMakeWithSeconds(localTime, preferredTimescale: 600))

                            // Get frame from source
                            let asset = AVURLAsset(url: clip.sourceURL)
                            let gen = AVAssetImageGenerator(asset: asset)
                            gen.appliesPreferredTrackTransform = false
                            gen.requestedTimeToleranceBefore = frameDuration
                            gen.requestedTimeToleranceAfter = frameDuration

                            guard let cgImage = try? gen.copyCGImage(at: sourceTime, actualTime: nil) else {
                                continue
                            }

                            var image = CIImage(cgImage: cgImage)

                            // Apply preferred transform
                            let transform = clip.preferredTransform
                            if transform != .identity {
                                image = image.transformed(by: transform)
                                let shifted = image.extent
                                if shifted.origin.x != 0 || shifted.origin.y != 0 {
                                    image = image.transformed(by: CGAffineTransform(
                                        translationX: -shifted.origin.x, y: -shifted.origin.y))
                                }
                            }

                            // Fit into render size
                            let ext = image.extent
                            if ext.width > 0 && ext.height > 0 {
                                let fitScale = min(renderSize.width / ext.width,
                                                   renderSize.height / ext.height)
                                if abs(fitScale - 1.0) > 0.001 {
                                    image = image.transformed(by: CGAffineTransform(
                                        scaleX: fitScale, y: fitScale))
                                }
                                let fitted = image.extent
                                let cx = (renderSize.width - fitted.width) / 2 - fitted.origin.x
                                let cy = (renderSize.height - fitted.height) / 2 - fitted.origin.y
                                image = image.transformed(by: CGAffineTransform(
                                    translationX: cx, y: cy))
                            }

                            // Animated transform (keyframes or static)
                            let animOffset: (x: CGFloat, y: CGFloat)
                            let animScale: CGFloat
                            let animRotation: CGFloat

                            if !clip.keyframes.isEmpty {
                                let interp = clip.interpolatedValues(at: time)
                                animOffset = (interp.offsetX, interp.offsetY)
                                animScale = interp.scale
                                animRotation = interp.rotation
                            } else {
                                animOffset = (clip.offsetX, clip.offsetY)
                                animScale = clip.scale
                                animRotation = clip.rotation
                            }

                            // Scale + rotation around center
                            let rcx = renderSize.width / 2
                            let rcy = renderSize.height / 2
                            if animScale != 1.0 || animRotation != 0 {
                                let rad = animRotation * .pi / 180.0
                                let t = CGAffineTransform(translationX: rcx, y: rcy)
                                    .scaledBy(x: animScale, y: animScale)
                                    .rotated(by: rad)
                                    .translatedBy(x: -rcx, y: -rcy)
                                image = image.transformed(by: t)
                            }

                            // Offset
                            if animOffset.x != 0 || animOffset.y != 0 {
                                image = image.transformed(by: CGAffineTransform(
                                    translationX: animOffset.x, y: -animOffset.y))
                            }

                            // Exposure
                            if clip.exposure != 0 {
                                image = image.applyingFilter("CIExposureAdjust",
                                                             parameters: [kCIInputEVKey: clip.exposure])
                            }

                            // Filter
                            if let filterName = clip.filter.ciFilterName {
                                var params: [String: Any] = [:]
                                switch clip.filter {
                                case .sepia:
                                    params[kCIInputIntensityKey] = clip.filterIntensity
                                case .vignette:
                                    params[kCIInputIntensityKey] = clip.filterIntensity * 2.0
                                    params[kCIInputRadiusKey] = 1.0
                                case .bloom:
                                    params[kCIInputIntensityKey] = clip.filterIntensity
                                    params[kCIInputRadiusKey] = 10.0
                                case .gaussianBlur:
                                    params[kCIInputRadiusKey] = clip.filterIntensity * 20.0
                                case .sharpen:
                                    params[kCIInputSharpnessKey] = clip.filterIntensity
                                default: break
                                }
                                image = image.applyingFilter(filterName, parameters: params)
                            }

                            image = image.cropped(to: renderRect)
                            composited = image.composited(over: composited)
                        }

                        // Draw text overlays
                        for overlay in overlaysSnapshot {
                            if seconds >= CMTimeGetSeconds(overlay.startTime) &&
                               seconds < CMTimeGetSeconds(overlay.endTime) {
                                let interp = overlay.interpolatedValues(at: time)
                                composited = EditorViewModel.drawTextForExport(
                                    overlay, interpolated: interp,
                                    on: composited, renderSize: renderSize)
                            }
                        }

                        // Render to pixel buffer
                        guard let pool = adaptor.pixelBufferPool else { continue }
                        var pixelBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                        guard let buffer = pixelBuffer else { continue }

                        ciContext.render(composited, to: buffer)
                        adaptor.append(buffer, withPresentationTime: time)

                        // Progress
                        Task { @MainActor in
                            self.exportProgress = Double(frameIndex) / Double(totalFrames)
                        }
                    }

                    videoInput.markAsFinished()
                    continuation.resume()
                }
            }

            // Write audio
            if let audioInput, let audioReaderOutput {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let q = DispatchQueue(label: "audioExportQueue")
                    audioInput.requestMediaDataWhenReady(on: q) {
                        while audioInput.isReadyForMoreMediaData {
                            if let sample = audioReaderOutput.copyNextSampleBuffer() {
                                audioInput.append(sample)
                            } else {
                                audioInput.markAsFinished()
                                continuation.resume()
                                return
                            }
                        }
                    }
                }
            }

            await writer.finishWriting()

            if writer.status == .completed {
                exportProgress = 1.0
                isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } else {
                errorMessage = "Export failed: \(writer.error?.localizedDescription ?? "Unknown")"
                showError = true
                isExporting = false
            }

        } catch {
            errorMessage = "Export error: \(error.localizedDescription)"
            showError = true
            isExporting = false
        }
    }

    /// Static text drawing for export (mirrors CustomCompositor.drawText)
    nonisolated private static func drawTextForExport(_ overlay: TextOverlay,
                                           interpolated: InterpolatedTextValues,
                                           on background: CIImage,
                                           renderSize: CGSize) -> CIImage {
        guard interpolated.opacity > 0.001 else { return background }

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                         CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else {
            return background
        }
        ctx.clear(CGRect(origin: .zero, size: renderSize))

        let font = NSFont(name: overlay.fontName, size: overlay.fontSize)
            ?? NSFont.systemFont(ofSize: overlay.fontSize, weight: .bold)
        let nsColor = NSColor(red: overlay.colorRed, green: overlay.colorGreen,
                              blue: overlay.colorBlue, alpha: overlay.colorAlpha)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: nsColor, .paragraphStyle: style
        ]
        let nsString = overlay.text as NSString
        let stringSize = nsString.size(withAttributes: attrs)

        let centerX = interpolated.positionX * renderSize.width
        let centerY = (1.0 - interpolated.positionY) * renderSize.height

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let transform = NSAffineTransform()
        transform.translateX(by: centerX, yBy: centerY)
        transform.rotate(byDegrees: interpolated.rotation)
        transform.scale(by: interpolated.scale)
        transform.translateX(by: -centerX, yBy: -centerY)
        transform.concat()

        nsString.draw(at: NSPoint(x: centerX - stringSize.width / 2,
                                   y: centerY - stringSize.height / 2),
                      withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return background }
        var textImage = CIImage(cgImage: cgImage)

        if interpolated.opacity < 0.999 {
            textImage = textImage.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: interpolated.opacity)
            ])
        }
        return textImage.composited(over: background)
    }

    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
    }
}
