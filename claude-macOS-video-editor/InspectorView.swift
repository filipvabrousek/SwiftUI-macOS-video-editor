import SwiftUI
import AVFoundation

struct InspectorView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Inspector", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let clip = viewModel.selectedClip, let index = viewModel.selectedClipIndex {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        clipInfoSection(clip)
                        Divider()
                        trimSection(clip, index: index)
                        Divider()
                        TransformInspectorSection(viewModel: viewModel, clip: clip)
                        Divider()
                        ClipKeyframeInspectorSection(viewModel: viewModel, clip: clip)
                        Divider()
                        exposureSection(clip, index: index)
                        Divider()
                        FilterInspectorSection(viewModel: viewModel, clip: clip)
                        Divider()
                        TrackInspectorSection(viewModel: viewModel, clip: clip)
                        Divider()
                        TextOverlayInspectorSection(viewModel: viewModel)
                    }
                    .padding(12)
                }
            } else if viewModel.selectedTextOverlayID != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextOverlayInspectorSection(viewModel: viewModel)
                    }
                    .padding(12)
                }
            } else {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Select a clip to inspect")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 240, idealWidth: 270)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Clip Info

    private func clipInfoSection(_ clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Clip Info", icon: "info.circle")

            LabeledContent("Name") {
                Text(clip.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Original") {
                Text(formattedDuration(CMTimeGetSeconds(clip.originalDuration)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Trimmed") {
                Text(formattedDuration(clip.trimmedDurationSeconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Track") {
                Text(clip.track == 0 ? "Main (V1)" : "Overlay V\(clip.track + 1)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Trim

    private func trimSection(_ clip: VideoClip, index: Int) -> some View {
        let originalDuration = CMTimeGetSeconds(clip.originalDuration)
        let trimStartBinding = Binding<Double>(
            get: { CMTimeGetSeconds(clip.trimStart) },
            set: { viewModel.updateTrimStart(clip.id, seconds: $0) }
        )
        let trimEndBinding = Binding<Double>(
            get: { CMTimeGetSeconds(clip.trimEnd) },
            set: { viewModel.updateTrimEnd(clip.id, seconds: $0) }
        )

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Trim", icon: "scissors")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("In Point")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formattedDuration(trimStartBinding.wrappedValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: trimStartBinding, in: 0...max(originalDuration - 0.1, 0.1))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Out Point")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formattedDuration(trimEndBinding.wrappedValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: trimEndBinding, in: 0.1...max(originalDuration, 0.2))
            }

            Button("Reset Trim") {
                viewModel.updateTrimStart(clip.id, seconds: 0)
                viewModel.updateTrimEnd(clip.id, seconds: originalDuration)
            }
            .font(.caption)
            .buttonStyle(.link)
        }
    }

    // MARK: - Exposure

    private func exposureSection(_ clip: VideoClip, index: Int) -> some View {
        let exposureBinding = Binding<Float>(
            get: { clip.exposure },
            set: { viewModel.updateExposure(clip.id, value: $0) }
        )

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Exposure", icon: "sun.max")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Adjustment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f EV", clip.exposure))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Slider(value: exposureBinding, in: -3.0...3.0, step: 0.1)

                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                exposurePreset("-1 EV", value: -1.0, clip: clip)
                exposurePreset("0 EV", value: 0.0, clip: clip)
                exposurePreset("+1 EV", value: 1.0, clip: clip)
                exposurePreset("+2 EV", value: 2.0, clip: clip)
            }

            Button("Reset Exposure") {
                viewModel.updateExposure(clip.id, value: 0.0)
            }
            .font(.caption)
            .buttonStyle(.link)
        }
    }

    private func exposurePreset(_ label: String, value: Float, clip: VideoClip) -> some View {
        Button(label) {
            viewModel.updateExposure(clip.id, value: value)
        }
        .font(.system(size: 10))
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(clip.exposure == value ? .accentColor : nil)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(.subheadline, weight: .semibold))
    }

    private func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let hundredths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, hundredths)
    }
}
