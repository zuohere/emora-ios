import SwiftUI

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var viewModel = EmoraViewModel()
    @State private var showPermissionAlert = false
    @State private var isInitializing = true

    // Colors from SPEC
    private let primaryColor = Color(hex: "6366F1")
    private let secondaryColor = Color(hex: "8B5CF6")

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black
                    .ignoresSafeArea()

                if isInitializing {
                    // Loading view
                    LoadingView()
                } else {
                    // Main content
                    VStack(spacing: 0) {
                        // Camera preview area with emotion overlay
                        ZStack(alignment: .topTrailing) {
                            // Camera preview
                            CameraPreviewContainer(videoManager: VideoCaptureManager.shared)
                                .frame(height: geometry.size.height * 0.55)

                            // Emotion visualization overlay (top right, gray transparent)
                            EmotionVisualizationContainer(viewModel: viewModel)
                                .frame(width: 180, height: 200)
                                .padding(.trailing, 16)
                                .padding(.top, 8)
                        }

                        // Control area - only response panel now
                        VStack(spacing: 16) {
                            // Response panel (full width, text history)
                            ResponsePanel(viewModel: viewModel)
                                .padding(.horizontal, 16)

                            // Control panel
                            ControlPanel(viewModel: viewModel)
                                .padding(.horizontal, 16)

                            // Bottom safe area
                            Spacer()
                                .frame(height: 16)
                        }
                        .frame(height: geometry.size.height * 0.45)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "1F2937"), Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
            }
        }
        .task {
            await initialize()
        }
        .alert("Permission Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Camera and microphone permissions are required for emotion analysis.")
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private func initialize() async {
        // Check permissions
        let hasPermissions = await viewModel.checkPermissions()

        if hasPermissions {
            // Setup media session
            await viewModel.setupMediaSession()
        } else {
            showPermissionAlert = true
        }

        isInitializing = false
    }
}

// MARK: - Loading View

struct LoadingView: View {
    @State private var isAnimating = false

    private let primaryColor = Color(hex: "6366F1")
    private let secondaryColor = Color(hex: "8B5CF6")

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [primaryColor.opacity(0.3), secondaryColor.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 4
                    )
                    .frame(width: 80, height: 80)

                // Inner ring
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(
                        LinearGradient(
                            colors: [primaryColor, secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 4
                    )
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(
                        .linear(duration: 1)
                        .repeatForever(autoreverses: false),
                        value: isAnimating
                    )

                // Center icon
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [primaryColor, secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("Initializing...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}

// MARK: - Emotion Visualization Container (Top Right Overlay)

struct EmotionVisualizationContainer: View {
    @ObservedObject var viewModel: EmoraViewModel

    private let surfaceColor = Color(hex: "1F2937")
    private let overlayColor = Color.black.opacity(0.6)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Emotion")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                // Status indicator
                if latestEmotionResult != nil {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.4))

            // Visualization content
            if let result = latestEmotionResult {
                ScrollView {
                    CompactEmotionView(result: result)
                        .padding(8)
                }
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 24))
                        .foregroundColor(Color.white.opacity(0.4))

                    Text("Waiting...")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(overlayColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var latestEmotionResult: EmotionAnalysisResult? {
        for response in viewModel.responses.reversed() {
            if let result = EmotionAnalysisResult.parse(from: response) {
                return result
            }
        }
        return nil
    }
}

// MARK: - Compact Emotion View (for overlay)

struct CompactEmotionView: View {
    let result: EmotionAnalysisResult

    private var dominant: (name: String, value: Double, color: String) {
        result.emotion.emotion.dominantEmotion
    }

    private var emotionNameCN: String {
        switch dominant.name {
        case "happy": return "开心"
        case "surprised": return "惊讶"
        case "angry": return "愤怒"
        case "disgusted": return "厌恶"
        case "sad": return "悲伤"
        case "fearful": return "恐惧"
        default: return "中性"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Dominant emotion
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: dominant.color))
                    .frame(width: 10, height: 10)

                Text(emotionNameCN)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Text("\(Int(dominant.value * 100))%")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.7))
            }

            // Emotion bars (compact)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(result.emotion.emotion.sortedEmotions.prefix(4), id: \.name) { item in
                    HStack(spacing: 6) {
                        Text(emotionNameCNfor(name: item.name))
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.6))
                            .frame(width: 28, alignment: .leading)

                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.2))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: item.color))
                                .frame(width: geometry.size.width * item.value, height: 4)
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }

    private func emotionNameCNfor(name: String) -> String {
        switch name {
        case "happy": return "开心"
        case "surprised": return "惊讶"
        case "angry": return "愤怒"
        case "disgusted": return "厌恶"
        case "sad": return "悲伤"
        case "fearful": return "恐惧"
        default: return "中性"
        }
    }
}
