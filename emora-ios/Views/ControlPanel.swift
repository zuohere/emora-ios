import SwiftUI

// MARK: - Control Panel

struct ControlPanel: View {
    @ObservedObject var viewModel: EmoraViewModel

    // Colors from SPEC
    private let primaryColor = Color(hex: "6366F1")
    private let secondaryColor = Color(hex: "8B5CF6")
    private let accentColor = Color(hex: "EC4899")
    private let surfaceColor = Color(hex: "1F2937")

    var body: some View {
        VStack(spacing: 20) {
            // Connection status
            ConnectionStatusBadge(state: viewModel.connectionState)

            // Main controls
            HStack(spacing: 24) {
                // Connect/Disconnect button
                ControlButton(
                    icon: viewModel.isConnected ? "wifi.slash" : "wifi",
                    title: viewModel.isConnected ? "Disconnect" : "Connect",
                    color: viewModel.isConnected ? Color(hex: "EF4444") : primaryColor,
                    isEnabled: true
                ) {
                    if viewModel.isConnected {
                        viewModel.disconnect()
                    } else {
                        viewModel.connect()
                    }
                }

                // Send Request button (s)
                ControlButton(
                    icon: "paperplane.fill",
                    title: "Send \"s\"",
                    color: accentColor,
                    isEnabled: viewModel.isConnected
                ) {
                    viewModel.sendAnalysisRequest()
                }

                // Switch Camera button
                ControlButton(
                    icon: "camera.rotate",
                    title: "Switch",
                    color: secondaryColor,
                    isEnabled: viewModel.isConnected
                ) {
                    viewModel.switchCamera()
                }
            }

            // Streaming status
            if viewModel.isStreaming {
                HStack(spacing: 16) {
                    StreamingIndicator(
                        isActive: viewModel.isVideoCapturing,
                        icon: "video.fill",
                        label: "Video"
                    )

                    StreamingIndicator(
                        isActive: viewModel.isAudioCapturing,
                        icon: "mic.fill",
                        label: "Audio"
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }
}

// MARK: - Connection Status Badge

struct ConnectionStatusBadge: View {
    let state: ConnectionState

    private var statusColor: Color {
        switch state {
        case .connected:
            return Color(hex: "10B981")
        case .connecting, .reconnecting:
            return Color(hex: "F59E0B")
        case .disconnected:
            return Color(hex: "9CA3AF")
        case .failed:
            return Color(hex: "EF4444")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(state.displayText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.2))
        )
    }
}

// MARK: - Control Button

struct ControlButton: View {
    let icon: String
    let title: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                        .shadow(color: color.opacity(0.5), radius: 10, x: 0, y: 5)

                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
}

// MARK: - Streaming Indicator

struct StreamingIndicator: View {
    let isActive: Bool
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            if isActive {
                Circle()
                    .fill(Color(hex: "10B981"))
                    .frame(width: 6, height: 6)
            }

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isActive ? Color(hex: "10B981") : Color(hex: "9CA3AF"))

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .white : Color(hex: "9CA3AF"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(hex: "1F2937").opacity(0.8))
        )
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        ControlPanel(viewModel: EmoraViewModel())
    }
}
