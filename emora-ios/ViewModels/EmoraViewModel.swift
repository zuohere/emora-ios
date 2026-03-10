import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - Emora ViewModel

@MainActor
class EmoraViewModel: ObservableObject {
    // MARK: - Published Properties

    // Connection state (refined state machine)
    @Published private(set) var connectionState: AppConnectionState = .disconnected
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

    // Queue stats for debug panel
    @Published private(set) var queueStats = StreamQueueStats()

    // MARK: - Private Properties

    private let webSocketManager = WebSocketManager.shared
    private let videoManager = VideoCaptureManager.shared
    private let audioManager = AudioCaptureManager.shared

    private var cancellables = Set<AnyCancellable>()
    private var vitalTimer: Timer?

    // Interruption handling
    private var isInterrupted = false

    // MARK: - Initialization

    init() {
        setupBindings()
        setupInterruptionHandling()
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
    }

    func disconnect() {
        stopStreaming()
        webSocketManager.disconnect()
    }

    // MARK: - Streaming Control

    func startStreaming() {
        // Check if connection is ready for streaming
        guard connectionState.canSendMedia else {
            print("[EmoraViewModel] Cannot start streaming - state: \(connectionState)")
            return
        }

        // Start video capture
        videoManager.startCapture()
        isVideoCapturing = true

        // Start audio capture
        audioManager.startCapture()
        isAudioCapturing = true

        // Start vital data sending
        startVitalDataSender()

        // Tell WebSocket to start streaming (starts queue sender)
        webSocketManager.startStreaming()

        isStreaming = true
    }

    func stopStreaming() {
        // Stop video capture
        videoManager.stopCapture()
        isVideoCapturing = false

        // Stop audio capture
        audioManager.stopCapture()
        isAudioCapturing = false

        // Stop vital data sender
        stopVitalDataSender()

        // Tell WebSocket to stop streaming
        webSocketManager.stopStreaming()

        isStreaming = false
    }

    // MARK: - Send Request

    func sendAnalysisRequest() {
        guard connectionState.canSendMedia else {
            errorMessage = "Please wait for connection to be ready"
            showError = true
            return
        }

        print("[EmoraViewModel] User triggered sendAnalysisRequest")
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
                    let wasConnected = self.connectionState.isActive
                    self.connectionState = state
                    self.isConnected = state.isActive

                    // Handle disconnection
                    if wasConnected && !state.isActive && !self.isInterrupted {
                        self.handleDisconnection()
                    }

                    // When transport connected, wait for app ready
                    if state == .transportConnected {
                        // Connection established at transport level
                    }

                    // When app ready, start streaming
                    if state == .appReady && !self.isStreaming {
                        self.videoManager.startPreview()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self.startStreaming()
                    }

                    // Handle error states
                    if case .failed(let error) = state {
                        self.errorMessage = error
                        self.showError = true
                    }
                }
            }
            .store(in: &cancellables)

        // Bind responses - use throttle to avoid too frequent updates
        webSocketManager.$responses
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] responses in
                self?.responses = responses
            }
            .store(in: &cancellables)

        webSocketManager.$lastResponse
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.latestResponse = response
            }
            .store(in: &cancellables)

        // Bind queue stats - throttle to 1 second
        webSocketManager.$queueStats
            .receive(on: DispatchQueue.main)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] stats in
                self?.queueStats = stats
            }
            .store(in: &cancellables)

        // Setup video callback
        videoManager.onVideoFrameEncoded = { [weak self] data, timestamp, frameIndex, width, height in
            Task { @MainActor in
                guard let self = self, self.connectionState.canSendMedia else { return }
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
                guard let self = self, self.connectionState.canSendMedia else { return }
                self.webSocketManager.sendAudioChunk(
                    data: data,
                    timestamp: timestamp,
                    chunkIndex: chunkIndex,
                    sampleRate: self.audioManager.sampleRate,
                    channels: self.audioManager.channels
                )
            }
        }
    }

    private func handleDisconnection() {
        // Only stop streaming if not user-initiated
        if isStreaming {
            stopStreaming()
        }
    }

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        // Audio session interruption
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioInterruption(notification)
            }
            .store(in: &cancellables)

        // Audio route change
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
            .store(in: &cancellables)

        // App lifecycle
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAppBackground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAppForeground()
            }
            .store(in: &cancellables)

        // Capture session errors
        videoManager.onCaptureError = { [weak self] error in
            Task { @MainActor in
                self?.handleCaptureError(error)
            }
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Audio session interrupted (e.g., phone call, Siri)
            print("[EmoraViewModel] Audio session interrupted")
            isInterrupted = true

            // Stop audio capture but keep video
            audioManager.stopCapture()
            isAudioCapturing = false

        case .ended:
            // Interruption ended
            print("[EmoraViewModel] Audio session interruption ended")
            isInterrupted = false

            // Check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume audio capture
                    audioManager.startCapture()
                    isAudioCapturing = true
                }
            }

        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged, etc.
            print("[EmoraViewModel] Audio route changed - device unavailable")
            // Restart audio capture
            if isStreaming && !isInterrupted {
                audioManager.stopCapture()
                audioManager.startCapture()
            }

        case .newDeviceAvailable:
            // New device connected
            print("[EmoraViewModel] Audio route changed - new device")

        default:
            break
        }
    }

    private func handleAppBackground() {
        print("[EmoraViewModel] App going to background")
        // Stop video capture to save resources
        if isStreaming {
            videoManager.stopCapture()
        }
    }

    private func handleAppForeground() {
        print("[EmoraViewModel] App returning to foreground")
        // Resume video capture after a short delay to let system settle
        if isStreaming && connectionState.canSendMedia {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.videoManager.startCapture()
            }
        }
    }

    private func handleCaptureError(_ error: Error) {
        print("[EmoraViewModel] Capture error: \(error.localizedDescription)")
        errorMessage = "Camera error: \(error.localizedDescription)"
        showError = true

        // Try to restart capture
        if isStreaming && connectionState.canSendMedia {
            videoManager.stopCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.videoManager.startCapture()
            }
        }
    }

    // MARK: - Vital Data

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
        guard connectionState.canSendMedia else { return }

        // Generate random vital data (for testing)
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
