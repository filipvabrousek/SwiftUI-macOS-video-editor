import SwiftUI
import AVFoundation

// MARK: - Text Overlay Keyframe Inspector

struct KeyframeInspectorSection: View {
    @Bindable var viewModel: EditorViewModel
    let overlay: TextOverlay
    @State private var diamondDragStartTime: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            keyframeTimeline
            keyframeList
            selectedKeyframeEditor
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Label("Keyframes", systemImage: "diamond.fill")
                .font(.system(.subheadline, weight: .semibold))
            Spacer()

            if !overlay.keyframes.isEmpty {
                Button {
                    viewModel.clearAllKeyframes(from: overlay.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove all keyframes")
            }

            Button {
                viewModel.addKeyframe(to: overlay.id)
            } label: {
                Image(systemName: "plus.diamond")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Add keyframe at playhead position")
        }
    }

    // MARK: - Mini Keyframe Timeline (with draggable diamonds)

    private var keyframeTimeline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Timeline")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            GeometryReader { geo in
                let w = geo.size.width
                let h: CGFloat = 24

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: h)

                    // Progress line (playhead relative to overlay)
                    let overlayStart = CMTimeGetSeconds(overlay.startTime)
                    let dur = overlay.durationSeconds
                    let progress: CGFloat = dur > 0
                        ? CGFloat((viewModel.currentTime - overlayStart) / dur)
                        : 0

                    if progress >= 0 && progress <= 1 {
                        Rectangle()
                            .fill(Color.red.opacity(0.6))
                            .frame(width: 1.5, height: h)
                            .offset(x: progress * w)
                    }

                    // Draggable keyframe diamonds
                    ForEach(overlay.keyframes) { kf in
                        let xPos = kf.normalizedTime * w
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                viewModel.selectedKeyframeID == kf.id
                                    ? Color.yellow
                                    : Color.orange
                            )
                            .frame(width: 16, height: h)
                            .contentShape(Rectangle())
                            .offset(x: xPos - 8)
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        if diamondDragStartTime[kf.id] == nil {
                                            diamondDragStartTime[kf.id] = kf.normalizedTime
                                            viewModel.selectedKeyframeID = kf.id
                                        }
                                        guard let startT = diamondDragStartTime[kf.id] else { return }
                                        let deltaNorm = value.translation.width / w
                                        let newTime = max(0, min(startT + deltaNorm, 1))
                                        viewModel.updateKeyframe(kf.id, in: overlay.id, normalizedTime: newTime)
                                    }
                                    .onEnded { _ in
                                        diamondDragStartTime.removeValue(forKey: kf.id)
                                    }
                            )
                            .onTapGesture {
                                viewModel.selectedKeyframeID = kf.id
                            }
                    }
                }
                .frame(height: h)
            }
            .frame(height: 24)
        }
    }

    // MARK: - Keyframe List

    @ViewBuilder
    private var keyframeList: some View {
        if !overlay.keyframes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(overlay.keyframes.sorted(by: { $0.normalizedTime < $1.normalizedTime })) { kf in
                    keyframeRow(kf)
                }
            }
        } else {
            Text("No keyframes — text uses static position")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        }
    }

    private func keyframeRow(_ kf: TextKeyframe) -> some View {
        let isSelected = viewModel.selectedKeyframeID == kf.id
        return HStack(spacing: 6) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 7))
                .foregroundStyle(isSelected ? .yellow : .orange)

            Text("\(Int(kf.normalizedTime * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 32, alignment: .leading)

            Text("P(\(Int(kf.positionX * 100)),\(Int(kf.positionY * 100)))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)

            if kf.rotation != 0 {
                Text("R\(Int(kf.rotation))°")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            if abs(kf.scale - 1.0) > 0.01 {
                Text("S\(Int(kf.scale * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
            }

            Spacer()

            Button {
                viewModel.removeKeyframe(kf.id, from: overlay.id)
                if viewModel.selectedKeyframeID == kf.id {
                    viewModel.selectedKeyframeID = nil
                }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.yellow.opacity(0.08) : Color.clear)
        .cornerRadius(3)
        .onTapGesture {
            viewModel.selectedKeyframeID = kf.id
        }
    }

    // MARK: - Selected Keyframe Editor

    @ViewBuilder
    private var selectedKeyframeEditor: some View {
        if let kfID = viewModel.selectedKeyframeID,
           let kf = overlay.keyframes.first(where: { $0.id == kfID }) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("Edit Keyframe", systemImage: "slider.horizontal.3")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                sliderRow(label: "Time", value: "\(Int(kf.normalizedTime * 100))%",
                    binding: Binding(
                        get: { Double(kf.normalizedTime) },
                        set: { viewModel.updateKeyframe(kfID, in: overlay.id, normalizedTime: CGFloat($0)) }
                    ), range: 0.0...1.0)

                sliderRow(label: "X Position", value: "\(Int(kf.positionX * 100))%",
                    binding: Binding(
                        get: { Double(kf.positionX) },
                        set: { viewModel.updateKeyframe(kfID, in: overlay.id, positionX: CGFloat($0)) }
                    ), range: 0.0...1.0)

                sliderRow(label: "Y Position", value: "\(Int(kf.positionY * 100))%",
                    binding: Binding(
                        get: { Double(kf.positionY) },
                        set: { viewModel.updateKeyframe(kfID, in: overlay.id, positionY: CGFloat($0)) }
                    ), range: 0.0...1.0)

                sliderRow(label: "Rotation", value: "\(Int(kf.rotation))°",
                    binding: Binding(
                        get: { Double(kf.rotation) },
                        set: { viewModel.updateKeyframe(kfID, in: overlay.id, rotation: CGFloat($0)) }
                    ), range: -360.0...360.0)

                sliderRow(label: "Scale", value: "\(Int(kf.scale * 100))%",
                    binding: Binding(
                        get: { Double(kf.scale) },
                        set: { viewModel.updateKeyframe(kfID, in: overlay.id, scale: CGFloat($0)) }
                    ), range: 0.1...5.0)

                sliderRow(label: "Opacity", value: "\(Int(kf.opacity * 100))%",
                    binding: Binding(
                        get: { Double(kf.opacity) },
                        set: { viewModel.updateKeyframe(kfID, in: overlay.id, opacity: CGFloat($0)) }
                    ), range: 0.0...1.0)
            }
        }
    }

    private func sliderRow(label: String, value: String,
                            binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
        }
    }
}

// MARK: - Clip Keyframe Inspector

struct ClipKeyframeInspectorSection: View {
    @Bindable var viewModel: EditorViewModel
    let clip: VideoClip
    @State private var diamondDragStartTime: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            clipKeyframeTimeline
            clipKeyframeList
            selectedClipKeyframeEditor
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Label("Keyframes", systemImage: "diamond.fill")
                .font(.system(.subheadline, weight: .semibold))
            Spacer()

            if !clip.keyframes.isEmpty {
                Button {
                    viewModel.clearAllClipKeyframes(from: clip.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove all keyframes")
            }

            Button {
                viewModel.addClipKeyframe(to: clip.id)
            } label: {
                Image(systemName: "plus.diamond")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Add keyframe at playhead position")
        }
    }

    // MARK: - Mini Keyframe Timeline (with draggable diamonds)

    private var clipKeyframeTimeline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Timeline")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            GeometryReader { geo in
                let w = geo.size.width
                let h: CGFloat = 24

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: h)

                    // Progress line (playhead relative to clip)
                    let clipStart = CMTimeGetSeconds(clip.startTimeInTimeline)
                    let dur = clip.trimmedDurationSeconds
                    let progress: CGFloat = dur > 0
                        ? CGFloat((viewModel.currentTime - clipStart) / dur)
                        : 0

                    if progress >= 0 && progress <= 1 {
                        Rectangle()
                            .fill(Color.red.opacity(0.6))
                            .frame(width: 1.5, height: h)
                            .offset(x: progress * w)
                    }

                    // Draggable keyframe diamonds
                    ForEach(clip.keyframes) { kf in
                        let xPos = kf.normalizedTime * w
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                viewModel.selectedClipKeyframeID == kf.id
                                    ? Color.yellow
                                    : Color.cyan
                            )
                            .frame(width: 16, height: h)
                            .contentShape(Rectangle())
                            .offset(x: xPos - 8)
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        if diamondDragStartTime[kf.id] == nil {
                                            diamondDragStartTime[kf.id] = kf.normalizedTime
                                            viewModel.selectedClipKeyframeID = kf.id
                                        }
                                        guard let startT = diamondDragStartTime[kf.id] else { return }
                                        let deltaNorm = value.translation.width / w
                                        let newTime = max(0, min(startT + deltaNorm, 1))
                                        viewModel.updateClipKeyframe(kf.id, in: clip.id, normalizedTime: newTime)
                                    }
                                    .onEnded { _ in
                                        diamondDragStartTime.removeValue(forKey: kf.id)
                                    }
                            )
                            .onTapGesture {
                                viewModel.selectedClipKeyframeID = kf.id
                            }
                    }
                }
                .frame(height: h)
            }
            .frame(height: 24)
        }
    }

    // MARK: - Keyframe List

    @ViewBuilder
    private var clipKeyframeList: some View {
        if !clip.keyframes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(clip.keyframes.sorted(by: { $0.normalizedTime < $1.normalizedTime })) { kf in
                    clipKeyframeRow(kf)
                }
            }
        } else {
            Text("No keyframes — clip uses static transform")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        }
    }

    private func clipKeyframeRow(_ kf: ClipKeyframe) -> some View {
        let isSelected = viewModel.selectedClipKeyframeID == kf.id
        return HStack(spacing: 6) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 7))
                .foregroundStyle(isSelected ? .yellow : .cyan)

            Text("\(Int(kf.normalizedTime * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 32, alignment: .leading)

            if kf.offsetX != 0 || kf.offsetY != 0 {
                Text("(\(Int(kf.offsetX)),\(Int(kf.offsetY)))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if kf.rotation != 0 {
                Text("R\(Int(kf.rotation))°")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            if abs(kf.scale - 1.0) > 0.01 {
                Text("S\(Int(kf.scale * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
            }

            Spacer()

            Button {
                viewModel.removeClipKeyframe(kf.id, from: clip.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.cyan.opacity(0.08) : Color.clear)
        .cornerRadius(3)
        .onTapGesture {
            viewModel.selectedClipKeyframeID = kf.id
        }
    }

    // MARK: - Selected Clip Keyframe Editor

    @ViewBuilder
    private var selectedClipKeyframeEditor: some View {
        if let kfID = viewModel.selectedClipKeyframeID,
           let kf = clip.keyframes.first(where: { $0.id == kfID }) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("Edit Keyframe", systemImage: "slider.horizontal.3")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                sliderRow(label: "Time", value: "\(Int(kf.normalizedTime * 100))%",
                    binding: Binding(
                        get: { Double(kf.normalizedTime) },
                        set: { viewModel.updateClipKeyframe(kfID, in: clip.id, normalizedTime: CGFloat($0)) }
                    ), range: 0.0...1.0)

                sliderRow(label: "X Offset", value: "\(Int(kf.offsetX)) px",
                    binding: Binding(
                        get: { Double(kf.offsetX) },
                        set: { viewModel.updateClipKeyframe(kfID, in: clip.id, offsetX: CGFloat($0)) }
                    ), range: -500.0...500.0)

                sliderRow(label: "Y Offset", value: "\(Int(kf.offsetY)) px",
                    binding: Binding(
                        get: { Double(kf.offsetY) },
                        set: { viewModel.updateClipKeyframe(kfID, in: clip.id, offsetY: CGFloat($0)) }
                    ), range: -500.0...500.0)

                sliderRow(label: "Rotation", value: "\(Int(kf.rotation))°",
                    binding: Binding(
                        get: { Double(kf.rotation) },
                        set: { viewModel.updateClipKeyframe(kfID, in: clip.id, rotation: CGFloat($0)) }
                    ), range: -360.0...360.0)

                sliderRow(label: "Scale", value: "\(Int(kf.scale * 100))%",
                    binding: Binding(
                        get: { Double(kf.scale) },
                        set: { viewModel.updateClipKeyframe(kfID, in: clip.id, scale: CGFloat($0)) }
                    ), range: 0.1...5.0)
            }
        }
    }

    private func sliderRow(label: String, value: String,
                            binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
        }
    }
}
