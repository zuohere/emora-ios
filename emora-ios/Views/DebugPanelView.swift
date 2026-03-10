import SwiftUI

// MARK: - Debug Panel View

struct DebugPanelView: View {
    @ObservedObject var viewModel: EmoraViewModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.blue)
                    Text("Debug Panel")
                        .font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                DebugPanelContent(viewModel: viewModel)
                    .padding(.horizontal, 12)
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Debug Panel Content

struct DebugPanelContent: View {
    @ObservedObject var viewModel: EmoraViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Connection State
            SectionRow(title: "Connection State", color: connectionStateColor) {
                Text(viewModel.connectionState.displayText)
                    .font(.system(.caption, design: .monospaced))
            }

            Divider()

            // Queue Statistics
            Text("Stream Queues")
                .font(.subheadline)
                .fontWeight(.semibold)

            QueueStatRow(
                label: "Video",
                count: viewModel.queueStats.videoQueueLength,
                drops: viewModel.queueStats.videoDropCount,
                latency: viewModel.queueStats.videoSendLatencyMs,
                color: .blue
            )

            QueueStatRow(
                label: "Audio",
                count: viewModel.queueStats.audioQueueLength,
                drops: viewModel.queueStats.audioDropCount,
                latency: viewModel.queueStats.audioSendLatencyMs,
                color: .green
            )

            QueueStatRow(
                label: "Vital",
                count: viewModel.queueStats.vitalQueueLength,
                drops: viewModel.queueStats.vitalDropCount,
                latency: nil,
                color: .orange
            )

            Divider()

            // Error Display
            if !viewModel.queueStats.lastSendError.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Last Error:")
                        .font(.caption)
                    Spacer()
                    Text(viewModel.queueStats.lastSendError)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            // Sender Status
            HStack {
                Circle()
                    .fill(viewModel.queueStats.isSenderRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Sender:")
                    .font(.caption)
                Spacer()
                Text(viewModel.queueStats.isSenderRunning ? "Running" : "Stopped")
                    .font(.system(.caption, design: .monospaced))
            }

            // Total Stats
            HStack {
                Text("Total Queue:")
                    .font(.caption)
                Spacer()
                Text("\(viewModel.queueStats.totalQueueLength)")
                    .font(.system(.caption, design: .monospaced))
                Text(" | Drops:")
                    .font(.caption)
                Text("\(viewModel.queueStats.totalDropCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(viewModel.queueStats.totalDropCount > 0 ? .red : .primary)
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private var connectionStateColor: Color {
        switch viewModel.connectionState {
        case .appReady, .streaming:
            return .green
        case .transportConnected, .triggered:
            return .blue
        case .connecting:
            return .orange
        case .disconnected, .closing:
            return .gray
        case .failed:
            return .red
        }
    }
}

// MARK: - Queue Stat Row

struct QueueStatRow: View {
    let label: String
    let count: Int
    let drops: Int
    let latency: Double?
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label + ":")
                .font(.caption)
            Spacer()
            Text("\(count)")
                .font(.system(.caption, design: .monospaced))
            if drops > 0 {
                Text("(\(drops)d)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.red)
            }
            if let latency = latency {
                Text(String(format: "%.1fms", latency))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Section Row

struct SectionRow<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title + ":")
                .font(.caption)
            Spacer()
            content()
        }
    }
}

// MARK: - Preview

struct DebugPanelView_Previews: PreviewProvider {
    static var previews: some View {
        DebugPanelView(viewModel: EmoraViewModel())
            .frame(width: 300)
            .padding()
    }
}
