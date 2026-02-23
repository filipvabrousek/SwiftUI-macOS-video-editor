import SwiftUI
import AVFoundation

struct TransformInspectorSection: View {
    @Bindable var viewModel: EditorViewModel
    let clip: VideoClip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transform", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(.subheadline, weight: .semibold))

            // X Offset
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("X Offset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(clip.offsetX)) px")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { clip.offsetX },
                        set: { viewModel.updateOffsetX(clip.id, value: $0) }
                    ),
                    in: -500...500
                )
            }

            // Y Offset
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Y Offset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(clip.offsetY)) px")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { clip.offsetY },
                        set: { viewModel.updateOffsetY(clip.id, value: $0) }
                    ),
                    in: -500...500
                )
            }

            // Scale
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Scale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(clip.scale * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { clip.scale },
                        set: { viewModel.updateScale(clip.id, value: $0) }
                    ),
                    in: 0.1...3.0
                )
            }

            // Rotation
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rotation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(clip.rotation))°")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { clip.rotation },
                        set: { viewModel.updateRotation(clip.id, value: $0) }
                    ),
                    in: -180...180
                )
            }

            Button("Reset Transform") {
                viewModel.updateOffset(clip.id, x: 0, y: 0)
                viewModel.updateScale(clip.id, value: 1.0)
                viewModel.updateRotation(clip.id, value: 0)
            }
            .font(.caption)
            .buttonStyle(.link)
        }
    }
}

struct FilterInspectorSection: View {
    @Bindable var viewModel: EditorViewModel
    let clip: VideoClip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Filter", systemImage: "camera.filters")
                .font(.system(.subheadline, weight: .semibold))

            Picker("Filter", selection: Binding(
                get: { clip.filter },
                set: { viewModel.updateFilter(clip.id, filter: $0) }
            )) {
                ForEach(VideoFilter.allCases) { filter in
                    Label(filter.displayName, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
            .pickerStyle(.menu)

            if clip.filter != .none {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Intensity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(clip.filterIntensity * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding<Double>(
                            get: { Double(clip.filterIntensity) },
                            set: { viewModel.updateFilterIntensity(clip.id, value: Float($0)) }
                        ),
                        in: 0.0...1.0
                    )
                }
            }

            if clip.filter != .none {
                Button("Remove Filter") {
                    viewModel.updateFilter(clip.id, filter: .none)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
    }
}

struct TrackInspectorSection: View {
    @Bindable var viewModel: EditorViewModel
    let clip: VideoClip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Track", systemImage: "square.3.layers.3d")
                .font(.system(.subheadline, weight: .semibold))

            HStack {
                Text("Current Track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(clip.track == 0 ? "Main (V1)" : "Overlay V\(clip.track + 1)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if clip.track == 0 {
                Button("Move to Overlay Track") {
                    viewModel.moveClipToTrack(clip.id, track: viewModel.trackCount)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Move to Main Track") {
                    viewModel.moveClipToTrack(clip.id, track: 0)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Start time — all clips are freely positioned
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Start Time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formattedTime(CMTimeGetSeconds(clip.startTimeInTimeline)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { CMTimeGetSeconds(clip.startTimeInTimeline) },
                        set: { viewModel.updateClipStartTimeInTimeline(clip.id, seconds: $0) }
                    ),
                    in: 0...max(viewModel.totalDuration + 5, 1)
                )
            }
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let hundredths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, hundredths)
    }
}
