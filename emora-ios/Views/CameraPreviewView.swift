import SwiftUI
import AVFoundation

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.session = session
    }
}

class CameraPreviewUIView: UIView {
    var session: AVCaptureSession? {
        didSet {
            guard let session = session else { return }
            previewLayer.session = session
            if session.isRunning {
                previewLayer.connection?.isEnabled = true
            }
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPreviewLayer()
    }

    private func setupPreviewLayer() {
        previewLayer.videoGravity = .resizeAspectFill
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

// MARK: - Camera Preview Container

struct CameraPreviewContainer: View {
    @ObservedObject var videoManager: VideoCaptureManager

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Black background
                Color.black
                    .ignoresSafeArea()

                // Camera preview
                if let session = videoManager.session {
                    CameraPreviewView(session: session)
                        .ignoresSafeArea()
                } else {
                    // Placeholder
                    VStack {
                        Image(systemName: "video.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("Camera not available")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                // Camera frame overlay
                CameraFrameOverlay()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - Camera Frame Overlay

struct CameraFrameOverlay: View {
    var body: some View {
        ZStack {
            // Top gradient
            VStack {
                LinearGradient(
                    gradient: Gradient(colors: [.black.opacity(0.6), .clear]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                Spacer()
            }

            // Bottom gradient
            VStack {
                Spacer()
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.6)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
            }

            // Corner indicators
            VStack {
                HStack {
                    CornerIndicator()
                    Spacer()
                    CornerIndicator()
                        .rotationEffect(.degrees(90))
                }
                Spacer()
                HStack {
                    CornerIndicator()
                        .rotationEffect(.degrees(-90))
                    Spacer()
                    CornerIndicator()
                        .rotationEffect(.degrees(180))
                }
            }
            .padding(30)
        }
    }
}

// MARK: - Corner Indicator

struct CornerIndicator: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 20))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 20, y: 0))
        }
        .stroke(Color.white.opacity(0.8), lineWidth: 2)
    }
}

// MARK: - Preview

#Preview {
    CameraPreviewContainer(videoManager: VideoCaptureManager.shared)
}
