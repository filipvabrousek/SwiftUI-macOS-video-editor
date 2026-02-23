import SwiftUI

struct ContentView: View {
    @State private var viewModel = EditorViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Main editor area: Preview + Inspector
            HSplitView {
                // Left: Video Preview
                PlayerView(viewModel: viewModel)
                    .frame(minWidth: 400)

                // Right: Inspector
                InspectorView(viewModel: viewModel)
                    .frame(minWidth: 240, maxWidth: 320)
            }
            .frame(minHeight: 300)

            Divider()

            // Bottom: Timeline
            TimelineView(viewModel: viewModel)
                .frame(minHeight: 140, idealHeight: 180)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.importClip()
                } label: {
                    Label("Import", systemImage: "plus.rectangle.on.folder")
                }
                .help("Import video clips")

                Button {
                    viewModel.splitClipAtPlayhead()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .help("Split clip at playhead (C)")
                .disabled(viewModel.clips.isEmpty)

                Button {
                    viewModel.addTextOverlay()
                } label: {
                    Label("Add Text", systemImage: "textformat")
                }
                .help("Add text overlay at current time")
                .disabled(viewModel.clips.isEmpty)

                if viewModel.isExporting {
                    ProgressView(value: viewModel.exportProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                } else {
                    Button {
                        viewModel.exportVideo()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export video")
                    .disabled(viewModel.clips.isEmpty)
                }
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred.")
        }
        .frame(minWidth: 1000, minHeight: 600)
        .background {
            // Hidden button for "C" key to split clip at playhead
            Button("") {
                viewModel.splitClipAtPlayhead()
            }
            .keyboardShortcut("c", modifiers: [])
            .hidden()
        }
    }
}
