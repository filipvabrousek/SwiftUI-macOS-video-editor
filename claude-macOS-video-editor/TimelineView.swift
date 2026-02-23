import SwiftUI
import AVFoundation

struct TimelineView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var pixelsPerSecond: CGFloat = 80
    @State private var trimDragStartValue: Double?
    @State private var isDraggingPlayhead = false
    @State private var clipDragOffset: [UUID: CGFloat] = [:]   // visual-only offset during drag
    @State private var clipDragStartTime: [UUID: Double] = [:] // captured model time at drag start
    @State private var textDragOffset: [UUID: CGFloat] = [:]
    @State private var textDragStartTime: [UUID: Double] = [:]
    private let trimHandleWidth: CGFloat = 8

    private let trackHeight: CGFloat = 56
    private let textLaneHeight: CGFloat = 30
    private let rulerHeight: CGFloat = 24
    private let minPixelsPerSecond: CGFloat = 20
    private let maxPixelsPerSecond: CGFloat = 300

    private var timelineWidth: CGFloat {
        max(CGFloat(viewModel.totalDuration) * pixelsPerSecond + 100, 600)
    }

    private var totalTrackAreaHeight: CGFloat {
        let videoTrackCount = CGFloat(viewModel.trackCount)
        let hasTextOverlays = !viewModel.textOverlays.isEmpty
        return videoTrackCount * (trackHeight + 1)
            + (hasTextOverlays ? textLaneHeight + 1 : 0)
            + 30 // add-track button area
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineToolbar
            Divider()
            timelineContent
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Toolbar

    private var timelineToolbar: some View {
        HStack(spacing: 12) {
            Label("Timeline", systemImage: "film")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $pixelsPerSecond, in: minPixelsPerSecond...maxPixelsPerSecond)
                    .frame(width: 100)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }

            Text(formattedTime(viewModel.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    private var timelineContent: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Layer 1: The track content (ruler ticks, clips, etc.)
                VStack(alignment: .leading, spacing: 0) {
                    timelineRuler
                    Divider()
                    allTracksArea
                }

                // Layer 2: Red playhead line + triangle (non-interactive, drawn on top)
                playheadLine

                // Layer 3: Ruler scrub/drag area (interactive, topmost)
                rulerScrubOverlay
            }
            .frame(width: timelineWidth)
        }
        .frame(minHeight: rulerHeight + totalTrackAreaHeight + 20)
    }

    // MARK: - Ruler

    private var timelineRuler: some View {
        Canvas { context, size in
            let totalSeconds = Int(ceil(viewModel.totalDuration)) + 2

            for second in 0...totalSeconds {
                let x = CGFloat(second) * pixelsPerSecond

                if x > size.width { break }

                let tickPath = Path { p in
                    p.move(to: CGPoint(x: x, y: size.height - 10))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(tickPath, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

                let text = Text(formattedTime(Double(second)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: x + 2, y: size.height - 16), anchor: .leading)

                if pixelsPerSecond > 40 {
                    for sub in 1..<4 {
                        let subX = x + CGFloat(sub) * pixelsPerSecond / 4
                        let subPath = Path { p in
                            p.move(to: CGPoint(x: subX, y: size.height - 5))
                            p.addLine(to: CGPoint(x: subX, y: size.height))
                        }
                        context.stroke(subPath, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                    }
                }
            }
        }
        .frame(height: rulerHeight)
    }

    // MARK: - All Tracks

    private var allTracksArea: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Main track (V1)
            trackLane(trackIndex: 0, label: "V1")

            // Overlay tracks
            ForEach(1..<viewModel.trackCount, id: \.self) { trackIndex in
                trackLane(trackIndex: trackIndex, label: "V\(trackIndex + 1)")
            }

            // Text overlay lane
            if !viewModel.textOverlays.isEmpty {
                textOverlayLane
            }

            // Add Track / Empty state
            HStack(spacing: 8) {
                if viewModel.clips.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "film.stack")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("Import clips to start editing")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            .frame(height: viewModel.clips.isEmpty ? trackHeight : 8)
        }
    }

    // MARK: - Track Lane

    private func trackLane(trackIndex: Int, label: String) -> some View {
        let trackClips = trackIndex == 0
            ? viewModel.mainTrackClips
            : viewModel.overlayClips(forTrack: trackIndex)

        return HStack(spacing: 0) {
            // Track label
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
                .frame(height: trackHeight)

            // Track content — all tracks use absolute positioning
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(trackIndex == 0 ? 0.08 : 0.04))
                    .frame(height: trackHeight)

                ForEach(trackClips) { clip in
                    let baseX = CGFloat(CMTimeGetSeconds(clip.startTimeInTimeline)) * pixelsPerSecond
                    let dragX = clipDragOffset[clip.id] ?? 0
                    clipView(clip)
                        .offset(x: baseX + dragX)
                }
            }
        }
    }

    // MARK: - Text Overlay Lane

    private var textOverlayLane: some View {
        HStack(spacing: 0) {
            Text("T")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
                .frame(height: textLaneHeight)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.yellow.opacity(0.03))
                    .frame(height: textLaneHeight)

                ForEach(viewModel.textOverlays) { overlay in
                    let baseX = CGFloat(CMTimeGetSeconds(overlay.startTime)) * pixelsPerSecond
                    let dragX = textDragOffset[overlay.id] ?? 0
                    let w = CGFloat(overlay.durationSeconds) * pixelsPerSecond
                    let isSelected = viewModel.selectedTextOverlayID == overlay.id

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.yellow.opacity(isSelected ? 0.35 : 0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    isSelected ? Color.yellow : Color.yellow.opacity(0.4),
                                    lineWidth: isSelected ? 1.5 : 0.5
                                )
                        )
                        .overlay(
                            HStack(spacing: 3) {
                                Image(systemName: "textformat")
                                    .font(.system(size: 8))
                                Text(overlay.text)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                                if !overlay.keyframes.isEmpty {
                                    Image(systemName: "diamond.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 4)
                        )
                        .frame(width: max(w, 20), height: textLaneHeight - 6)
                        .offset(x: baseX + dragX)
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if textDragStartTime[overlay.id] == nil {
                                        textDragStartTime[overlay.id] = CMTimeGetSeconds(overlay.startTime)
                                        viewModel.selectedTextOverlayID = overlay.id
                                        viewModel.selectedClipID = nil
                                    }
                                    // Only update visual offset — no model mutation during drag
                                    textDragOffset[overlay.id] = value.translation.width
                                }
                                .onEnded { value in
                                    // Commit final position to model
                                    if let startTime = textDragStartTime[overlay.id] {
                                        let delta = Double(value.translation.width) / Double(pixelsPerSecond)
                                        viewModel.moveTextOverlayPosition(overlay.id, startSeconds: startTime + delta)
                                    }
                                    textDragOffset.removeValue(forKey: overlay.id)
                                    textDragStartTime.removeValue(forKey: overlay.id)
                                    viewModel.rebuildPlayerComposition()
                                }
                        )
                        .onTapGesture {
                            viewModel.selectedTextOverlayID = overlay.id
                            viewModel.selectedClipID = nil
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                viewModel.removeTextOverlay(overlay.id)
                            }
                        }
                }
            }
        }
    }

    // MARK: - Clip View

    private func clipView(_ clip: VideoClip) -> some View {
        let width = max(CGFloat(clip.trimmedDurationSeconds) * pixelsPerSecond, 40)
        let isSelected = clip.id == viewModel.selectedClipID
        let isOverlay = clip.track > 0

        return HStack(spacing: 0) {
            trimHandle(edge: .leading, clip: clip)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isSelected
                          ? (isOverlay ? Color.green.opacity(0.25) : Color.accentColor.opacity(0.25))
                          : (isOverlay ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12)))

                if let thumbnail = clip.thumbnailImage {
                    HStack(spacing: 0) {
                        let bodyWidth = max(width - trimHandleWidth * 2, 1)
                        let count = max(1, Int(bodyWidth / 60))
                        ForEach(0..<count, id: \.self) { _ in
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: bodyWidth / CGFloat(count), height: trackHeight - 20)
                                .clipped()
                                .opacity(0.4)
                        }
                    }
                    .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .primary : .secondary)

                    Text(formattedTime(clip.trimmedDurationSeconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

                // Effect badges
                VStack {
                    HStack(spacing: 2) {
                        Spacer()
                        if clip.exposure != 0 {
                            Image(systemName: "sun.max.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.orange)
                        }
                        if clip.filter != .none {
                            Image(systemName: "camera.filters")
                                .font(.system(size: 7))
                                .foregroundStyle(.purple)
                        }
                        if clip.hasTransformModifications {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 7))
                                .foregroundStyle(.cyan)
                        }
                        if clip.hasKeyframes {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.yellow)
                        }
                    }
                    .padding(3)
                    Spacer()
                }
            }
            .frame(width: max(width - trimHandleWidth * 2, 1))
            .onTapGesture {
                viewModel.selectedClipID = clip.id
                viewModel.selectedTextOverlayID = nil
            }

            trimHandle(edge: .trailing, clip: clip)
        }
        .frame(height: trackHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected
                        ? (isOverlay ? Color.green : Color.accentColor)
                        : (isOverlay ? Color.green.opacity(0.3) : Color.accentColor.opacity(0.3)),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if clipDragStartTime[clip.id] == nil {
                        clipDragStartTime[clip.id] = CMTimeGetSeconds(clip.startTimeInTimeline)
                        viewModel.selectedClipID = clip.id
                    }
                    // Only update visual offset — no model mutation during drag
                    clipDragOffset[clip.id] = value.translation.width
                }
                .onEnded { value in
                    // Commit final position to model
                    if let startTime = clipDragStartTime[clip.id] {
                        let deltaSeconds = Double(value.translation.width) / Double(pixelsPerSecond)
                        let newStart = max(0, startTime + deltaSeconds)
                        viewModel.moveClipPosition(clip.id, seconds: newStart)
                    }
                    clipDragOffset.removeValue(forKey: clip.id)
                    clipDragStartTime.removeValue(forKey: clip.id)
                    viewModel.rebuildPlayerComposition()
                }
        )
        .contextMenu {
            if clip.track == 0 {
                Button("Move to Overlay Track") {
                    viewModel.moveClipToTrack(clip.id, track: viewModel.trackCount)
                }
            } else {
                Button("Move to Main Track") {
                    viewModel.moveClipToTrack(clip.id, track: 0)
                }
            }
            Divider()
            Button("Remove Clip", role: .destructive) {
                viewModel.removeClip(clip.id)
            }
        }
    }

    // MARK: - Trim Handle

    private func trimHandle(edge: HorizontalEdge, clip: VideoClip) -> some View {
        let isIn = edge == .leading

        return Rectangle()
            .fill(Color.accentColor.opacity(0.35))
            .frame(width: trimHandleWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 2, height: 20)
            )
            .contentShape(Rectangle())
            .cursor(NSCursor.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if trimDragStartValue == nil {
                            trimDragStartValue = isIn
                                ? CMTimeGetSeconds(clip.trimStart)
                                : CMTimeGetSeconds(clip.trimEnd)
                        }
                        guard let startValue = trimDragStartValue else { return }

                        let deltaSeconds = Double(value.translation.width) / Double(pixelsPerSecond)

                        if isIn {
                            viewModel.updateTrimStart(clip.id, seconds: startValue + deltaSeconds)
                        } else {
                            viewModel.updateTrimEnd(clip.id, seconds: startValue + deltaSeconds)
                        }
                    }
                    .onEnded { _ in
                        trimDragStartValue = nil
                    }
            )
            .onTapGesture {
                viewModel.selectedClipID = clip.id
            }
    }

    // MARK: - Playhead

    private let trackLabelWidth: CGFloat = 24

    /// The non-interactive red vertical line spanning the full timeline height.
    private var playheadLine: some View {
        let totalHeight = rulerHeight + totalTrackAreaHeight
        let xPos = CGFloat(viewModel.currentTime) * pixelsPerSecond + trackLabelWidth

        return Canvas { context, size in
            // Red vertical line
            let linePath = Path { p in
                p.move(to: CGPoint(x: xPos, y: 0))
                p.addLine(to: CGPoint(x: xPos, y: size.height))
            }
            context.stroke(linePath, with: .color(.red), lineWidth: 1.5)

            // Playhead triangle at top
            let headWidth: CGFloat = 14
            let headHeight: CGFloat = 10
            let headPath = Path { p in
                p.move(to: CGPoint(x: xPos, y: headHeight))
                p.addLine(to: CGPoint(x: xPos - headWidth / 2, y: 3))
                p.addLine(to: CGPoint(x: xPos - headWidth / 2, y: 0))
                p.addLine(to: CGPoint(x: xPos + headWidth / 2, y: 0))
                p.addLine(to: CGPoint(x: xPos + headWidth / 2, y: 3))
                p.closeSubpath()
            }
            context.fill(headPath, with: .color(.red))
        }
        .frame(width: timelineWidth, height: totalHeight)
        .allowsHitTesting(false)
    }

    /// Interactive overlay for the ruler area: click or drag anywhere to seek,
    /// including grabbing the playhead triangle.
    private var rulerScrubOverlay: some View {
        Color.clear
            .frame(width: timelineWidth, height: rulerHeight)
            .contentShape(Rectangle())
            .cursor(NSCursor.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        isDraggingPlayhead = true
                        let x = value.location.x - trackLabelWidth
                        let seconds = max(0, min(Double(x / pixelsPerSecond), viewModel.totalDuration))
                        viewModel.seek(to: seconds)
                    }
                    .onEnded { _ in
                        isDraggingPlayhead = false
                    }
            )
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds.truncatingRemainder(dividingBy: 1)) * 30)
        return String(format: "%d:%02d:%02d", mins, secs, frames)
    }
}

// MARK: - Playhead Shape

struct PlayheadShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 3))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 3))
            p.closeSubpath()
        }
    }
}

// MARK: - Resize Cursor Modifier

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
