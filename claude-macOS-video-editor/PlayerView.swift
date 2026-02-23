import SwiftUI
import AVKit

struct PlayerView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Video preview area
            ZStack {
                Rectangle()
                    .fill(Color.black)

                if let player = viewModel.player {
                    VideoPlayer(player: player)
                        .disabled(true) // We control playback ourselves
                } else {
                    emptyState
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Transport controls
            transportControls
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No clips loaded")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            // Go to start
            Button {
                viewModel.seek(to: 0)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.clips.isEmpty)

            // Step backward
            Button {
                viewModel.seek(to: max(0, viewModel.currentTime - 1.0 / 30.0))
            } label: {
                Image(systemName: "backward.frame.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.clips.isEmpty)

            // Play / Pause
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(viewModel.clips.isEmpty)

            // Step forward
            Button {
                viewModel.seek(to: min(viewModel.totalDuration, viewModel.currentTime + 1.0 / 30.0))
            } label: {
                Image(systemName: "forward.frame.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.clips.isEmpty)

            // Go to end
            Button {
                viewModel.seek(to: viewModel.totalDuration)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.clips.isEmpty)

            Spacer()

            // Time display
            Text(timeDisplay)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var timeDisplay: String {
        let current = formattedTimecode(viewModel.currentTime)
        let total = formattedTimecode(viewModel.totalDuration)
        return "\(current) / \(total)"
    }

    private func formattedTimecode(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds.truncatingRemainder(dividingBy: 1)) * 30)
        return String(format: "%d:%02d:%02d", mins, secs, frames)
    }
}
