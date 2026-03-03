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
                        // Camera preview (takes most of the screen)
                        CameraPreviewContainer(videoManager: VideoCaptureManager.shared)
                            .frame(height: geometry.size.height * 0.55)

                        // Control area
                        VStack(spacing: 16) {
                            // Response panel
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
