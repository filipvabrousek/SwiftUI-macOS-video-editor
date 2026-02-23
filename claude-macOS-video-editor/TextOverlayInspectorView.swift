import SwiftUI
import AVFoundation

struct TextOverlayInspectorSection: View {
    @Bindable var viewModel: EditorViewModel

    private let availableFonts = [
        "Helvetica-Bold",
        "Helvetica",
        "Arial",
        "Arial-BoldMT",
        "Georgia-Bold",
        "Georgia",
        "Courier-Bold",
        "Courier",
        "Futura-Medium",
        "Futura-Bold",
        "Avenir-Heavy",
        "Avenir-Medium",
        "Menlo-Bold",
        "Menlo-Regular"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            overlayListSection
            selectedEditorSection
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Label("Text Overlays", systemImage: "textformat")
                .font(.system(.subheadline, weight: .semibold))
            Spacer()
            Button {
                viewModel.addTextOverlay()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.clips.isEmpty)
        }
    }

    // MARK: - Overlay List

    @ViewBuilder
    private var overlayListSection: some View {
        if !viewModel.textOverlays.isEmpty {
            ForEach(viewModel.textOverlays) { overlay in
                overlayRow(overlay)
            }
        }
    }

    private func overlayRow(_ overlay: TextOverlay) -> some View {
        let isSelected = viewModel.selectedTextOverlayID == overlay.id
        return HStack {
            Image(systemName: "textformat.abc")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text(overlay.text)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                   // .foregroundStyle(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .onTapGesture {
            viewModel.selectedTextOverlayID = overlay.id
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                viewModel.removeTextOverlay(overlay.id)
            }
        }
    }

    // MARK: - Selected Editor

    @ViewBuilder
    private var selectedEditorSection: some View {
        if let overlay = viewModel.selectedTextOverlay {
            Divider()
            textContentSection(overlay)
            fontSection(overlay)
            fontSizeSection(overlay)
            colorSection(overlay)
            positionSection(overlay)
            timingSection(overlay)
            Divider()
            KeyframeInspectorSection(viewModel: viewModel, overlay: overlay)
            deleteSection(overlay)
        }
    }

    // MARK: - Sub-sections

    private func textContentSection(_ overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Content")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Text", text: Binding(
                get: { overlay.text },
                set: { viewModel.updateTextOverlayText(overlay.id, text: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption))
        }
    }

    private func fontSection(_ overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Font")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Font", selection: Binding(
                get: { overlay.fontName },
                set: { viewModel.updateTextOverlayFont(overlay.id, fontName: $0) }
            )) {
                ForEach(availableFonts, id: \.self) { fontName in
                    Text(fontName.replacingOccurrences(of: "-", with: " "))
                        .tag(fontName)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func fontSizeSection(_ overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(overlay.fontSize)) pt")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { overlay.fontSize },
                    set: { viewModel.updateTextOverlayFontSize(overlay.id, size: $0) }
                ),
                in: 12.0...120.0
            )
        }
    }

    private func colorSection(_ overlay: TextOverlay) -> some View {
        let colorBinding = Binding<Color>(
            get: {
                Color(
                    red: overlay.colorRed,
                    green: overlay.colorGreen,
                    blue: overlay.colorBlue,
                    opacity: overlay.colorAlpha
                )
            },
            set: { newColor in
                let resolved = NSColor(newColor)
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                resolved.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                viewModel.updateTextOverlayColor(overlay.id, red: r, green: g, blue: b, alpha: a)
            }
        )

        return VStack(alignment: .leading, spacing: 4) {
            Text("Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            ColorPicker("Text Color", selection: colorBinding)
                .labelsHidden()
        }
    }

    private func positionSection(_ overlay: TextOverlay) -> some View {
        let xBinding = Binding<Double>(
            get: { overlay.positionX },
            set: { viewModel.updateTextOverlayPosition(overlay.id, x: $0, y: overlay.positionY) }
        )
        let yBinding = Binding<Double>(
            get: { overlay.positionY },
            set: { viewModel.updateTextOverlayPosition(overlay.id, x: overlay.positionX, y: $0) }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("X Position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(overlay.positionX * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: xBinding, in: 0.0...1.0)

            HStack {
                Text("Y Position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(overlay.positionY * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: yBinding, in: 0.0...1.0)
        }
    }

    private func timingSection(_ overlay: TextOverlay) -> some View {
        let maxDuration = max(viewModel.totalDuration, 1.0)
        let startBinding = Binding<Double>(
            get: { CMTimeGetSeconds(overlay.startTime) },
            set: {
                viewModel.updateTextOverlayTiming(
                    overlay.id,
                    startSeconds: $0,
                    endSeconds: CMTimeGetSeconds(overlay.endTime)
                )
            }
        )
        let endBinding = Binding<Double>(
            get: { CMTimeGetSeconds(overlay.endTime) },
            set: {
                viewModel.updateTextOverlayTiming(
                    overlay.id,
                    startSeconds: CMTimeGetSeconds(overlay.startTime),
                    endSeconds: $0
                )
            }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedTime(CMTimeGetSeconds(overlay.startTime)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: startBinding, in: 0.0...maxDuration)

            HStack {
                Text("End")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedTime(CMTimeGetSeconds(overlay.endTime)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: endBinding, in: 0.0...maxDuration)
        }
    }

    private func deleteSection(_ overlay: TextOverlay) -> some View {
        Button("Delete Text Overlay", role: .destructive) {
            viewModel.removeTextOverlay(overlay.id)
        }
        .font(.caption)
        .buttonStyle(.link)
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let hundredths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, hundredths)
    }
}
