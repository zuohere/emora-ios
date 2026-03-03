import Foundation
import AVFoundation
import Combine
import SwiftUI

// MARK: - Emora ViewModel

@MainActor
class EmoraViewModel: ObservableObject {
    // MARK: - Published Properties

    // Connection state
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isConnected: Bool = false

    // Media capture state
    @Published private(set) var isVideoCapturing: Bool = false
    @Published private(set) var isAudioCapturing: Bool = false
    @Published var useFrontCamera: Bool = true

    // Response display
    @Published private(set) var responses: [String] = []
    @Published private(set) var latestResponse: String = ""
    @Published private(set) var isStreaming: Bool = false

    // Error handling
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""

    // MARK: - Private Properties

    private let webSocketManager = WebSocketManager.shared
    private let videoManager = VideoCaptureManager.shared
    private let audioManager = AudioCaptureManager.shared

    private var cancellables = Set<AnyCancellable>()
    private var vitalTimer: Timer?

    // MARK: - Initialization

    init() {
        setupBindings()
    }

    // MARK: - Public Methods

    // MARK: - Permission Handling

    func checkPermissions() async -> Bool {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        var cameraGranted = cameraStatus == .authorized
        var micGranted = micStatus == .authorized

        if cameraStatus == .notDetermined {
            cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        }

        if micStatus == .notDetermined {
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if !cameraGranted {
            errorMessage = "Camera permission is required for emotion analysis"
            showError = true
        }

        if !micGranted {
            errorMessage = "Microphone permission is required for emotion analysis"
            showError = true
        }

        return cameraGranted && micGranted
    }

    // MARK: - Session Setup

    func setupMediaSession() async {
        do {
            try videoManager.setupSession()
            try audioManager.setupSession()
            // Don't start preview here - only start when connected
        } catch {
            errorMessage = "Failed to setup media: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Connection Control

    func connect() {
        // Start camera when user clicks connect
        videoManager.startCapture()
        webSocketManager.connect()
        // Start streaming after connection is established (handled in binding)
    }

    func disconnect() {
        stopStreaming()
        webSocketManager.disconnect()
    }

    // MARK: - Streaming Control

    func startStreaming() {
        // Don't show error if already connected - this handles race conditions
        guard connectionState.isConnected || webSocketManager.connectionState.isConnected else {
            // Silently return instead of showing error
            // print("[EmoraViewModel] startStreaming skipped - not connected yet")
            return
        }

        // print("[EmoraViewModel] Starting streaming...")

        // Start video capture (preview + encoding)
        videoManager.startCapture()
        isVideoCapturing = true
        // print("[EmoraViewModel] Video capture started")

        // Start audio capture
        audioManager.startCapture()
        isAudioCapturing = true
        // print("[EmoraViewModel] Audio capture started")

        // Start vital data sending (every 2 seconds)
        startVitalDataSender()
        // print("[EmoraViewModel] Vital data sender started")

        isStreaming = true
        // print("[EmoraViewModel] Streaming is now active")
    }

    func stopStreaming() {
        // print("[EmoraViewModel] Stopping streaming...")

        // Stop video capture
        videoManager.stopCapture()
        isVideoCapturing = false
        // print("[EmoraViewModel] Video capture stopped")

        // Stop audio capture
        audioManager.stopCapture()
        isAudioCapturing = false
        // print("[EmoraViewModel] Audio capture stopped")

        // Stop vital data sender
        stopVitalDataSender()

        isStreaming = false
        // print("[EmoraViewModel] Streaming stopped")
    }

    // MARK: - Send Request

    func sendAnalysisRequest() {
        // print("[EmoraViewModel] sendAnalysisRequest called, isConnected: \(connectionState.isConnected)")

        guard connectionState.isConnected || webSocketManager.connectionState.isConnected else {
            errorMessage = "Please connect to the server first"
            showError = true
            // print("[EmoraViewModel] sendAnalysisRequest FAILED: Not connected")
            return
        }

        // print("[EmoraViewModel] Sending text message...")
        webSocketManager.sendTextMessage()
    }

    // MARK: - Camera Control

    func switchCamera() {
        videoManager.switchCamera()
        useFrontCamera = !useFrontCamera
    }

    // MARK: - Response Control

    func clearResponses() {
        webSocketManager.clearResponses()
    }

    // MARK: - Private Methods

    private func setupBindings() {
        // Bind WebSocket connection state
        webSocketManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    let wasConnected = self.connectionState.isConnected
                    self.connectionState = state
                    self.isConnected = state.isConnected

                    // print("[Binding] Connection state changed: \(state) -> wasConnected: \(wasConnected), new isConnected: \(state.isConnected)")

                    // Handle disconnection - stop streaming when disconnected
                    if wasConnected && !state.isConnected {
                        // print("[EmoraViewModel] Connection lost, stopping streaming...")
                        self.stopStreaming()
                    }

                    // When connected (first time or reconnected), start streaming
                    if !wasConnected && state.isConnected {
                        // print("[Binding] Connection established, starting streaming...")
                        // Start camera preview first
                        self.videoManager.startPreview()
                        // Wait 1 second for connection to stabilize, then start streaming
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        self.startStreaming()
                    }
                }
            }
            .store(in: &cancellables)

        // Bind responses
        webSocketManager.$responses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] responses in
                Task { @MainActor in
                    self?.responses = responses
                }
            }
            .store(in: &cancellables)

        webSocketManager.$lastResponse
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                Task { @MainActor in
                    self?.latestResponse = response
                }
            }
            .store(in: &cancellables)

        // Setup video callback
        videoManager.onVideoFrameEncoded = { [weak self] data, timestamp, frameIndex, width, height in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.connectionState.isConnected {
                    // print("[VideoCallback] Skipping - not connected, state: \(self.connectionState)")
                    return
                }
                // print("[VideoCallback] Sending frame \(frameIndex), size: \(data.count)")
                self.webSocketManager.sendVideoFrame(
                    data: data,
                    timestamp: timestamp,
                    frameIndex: frameIndex,
                    width: width,
                    height: height
                )
            }
        }

        // Setup audio callback
        audioManager.onAudioData = { [weak self] data, timestamp, chunkIndex in
            Task { @MainActor in
                guard let self = self, self.connectionState.isConnected else { return }
                self.webSocketManager.sendAudioChunk(
                    data: data,
                    timestamp: timestamp,
                    chunkIndex: chunkIndex,
                    sampleRate: self.audioManager.sampleRate,
                    channels: self.audioManager.channels
                )
            }
        }

        // Setup WebSocket connected callback (optional - binding already handles streaming start)
        webSocketManager.onConnected = {
            // Connection is handled in binding via connectionState changes
        }
    }

    private func startVitalDataSender() {
        vitalTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(handleVitalTimer), userInfo: nil, repeats: true)
    }

    @objc private func handleVitalTimer() {
        sendVitalData()
    }

    private func stopVitalDataSender() {
        vitalTimer?.invalidate()
        vitalTimer = nil
    }

    private func sendVitalData() {
        guard connectionState.isConnected else { return }

        // Generate random vital data (like client.py)
        let heartRate = Double.random(in: 70...90)
        let breathRate = Double.random(in: 12...20)
        let breathAmp = Double.random(in: 0.5...1.0)
        let conf = Double.random(in: 0.8...0.99)

        webSocketManager.sendVitalData(
            heartRate: heartRate,
            breathRate: breathRate,
            breathAmp: breathAmp,
            conf: conf
        )
    }
}
