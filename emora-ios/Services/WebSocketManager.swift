import Foundation
import Combine

// MARK: - App Connection State (Refined State Machine)

enum AppConnectionState: Equatable {
    // Transport layer states
    case disconnected
    case connecting
    case transportConnected    // WebSocket handshake done, but app layer not ready
    case appReady              // Application layer acknowledged, can send media

    // Application states
    case streaming             // Actively streaming video/audio/vital
    case triggered            // Sent text, waiting for chunk/final response
    case closing               // Graceful shutdown in progress

    // Error state
    case failed(String)

    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .transportConnected:
            return "Transport Ready"
        case .appReady:
            return "Ready"
        case .streaming:
            return "Streaming"
        case .triggered:
            return "Waiting Response"
        case .closing:
            return "Closing..."
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    var canSendMedia: Bool {
        switch self {
        case .transportConnected, .appReady, .streaming, .triggered:
            return true
        default:
            return false
        }
    }

    var isActive: Bool {
        switch self {
        case .transportConnected, .appReady, .streaming, .triggered:
            return true
        default:
            return false
        }
    }
}

// MARK: - WebSocket Manager

class WebSocketManager: NSObject, ObservableObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    // MARK: - Published Properties

    @Published private(set) var connectionState: AppConnectionState = .disconnected
    @Published private(set) var lastResponse: String = ""
    @Published private(set) var responses: [String] = []
    @Published private(set) var queueStats = StreamQueueStats()

    // MARK: - Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 30

    // Flag to track if we've received server acknowledgment
    private var isUserDisconnected = false

    // Stream queue manager
    private let streamQueue = StreamQueueManager.shared

    // Token (from AppConfig - should use secure storage in production)
    private var authToken: String = AppConfig.authToken

    // Current request tracking
    private var currentRequestId: String?

    // Message deduplication
    private var seenMessageHashes = Set<String>()
    private let seenMessagesLock = NSLock()
    private let maxSeenMessages = 500

    // Callbacks
    var onConnected: (() -> Void)?
    var onAppReady: (() -> Void)?
    var onStreamingStarted: (() -> Void)?
    var onTriggered: ((String) -> Void)?  // request_id

    // MARK: - Singleton

    static let shared = WebSocketManager()

    private override init() {
        super.init()
        setupStreamQueue()
    }

    // MARK: - Configuration

    /// Get WebSocket URL with token
    private var wsURL: String {
        // Use AppConfig for configuration
        let baseURL = AppConfig.webSocketBaseURL
        if !authToken.isEmpty {
            return "\(baseURL)?token=\(authToken)"
        }
        return baseURL
    }

    // MARK: - Public Methods

    func connect() {
        guard connectionState != .appReady && connectionState != .transportConnected &&
              connectionState != .connecting else {
            return
        }

        // Clean up existing connection
        cleanupConnection()
        isUserDisconnected = false
        connectionState = .connecting

        guard let url = URL(string: wsURL) else {
            connectionState = .failed("Invalid URL")
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true

        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Start receiving messages
        receiveMessage()
    }

    func disconnect() {
        isUserDisconnected = true
        connectionState = .closing

        // Stop streaming first
        stopStreaming()

        // Stop queue sender
        streamQueue.stopSender()

        // Clean up connection
        cleanupConnection()
        connectionState = .disconnected
    }

    private func cleanupConnection() {
        stopHeartbeat()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        reconnectAttempt = 0
        currentRequestId = nil
    }

    // MARK: - Streaming Control

    func startStreaming() {
        guard connectionState.canSendMedia else {
            print("[WebSocket] Cannot start streaming - state: \(connectionState)")
            return
        }

        connectionState = .streaming
        streamQueue.startSender()
        onStreamingStarted?()
    }

    func stopStreaming() {
        streamQueue.stopSender()
        streamQueue.clearQueues()

        if connectionState == .streaming || connectionState == .triggered {
            connectionState = .appReady
        }
    }

    // MARK: - Send Methods (Queue-based)

    func sendTextMessage() {
        guard connectionState.canSendMedia else {
            print("[WebSocket] Cannot send text - not ready, state: \(connectionState)")
            return
        }

        // Generate request_id (for tracking locally, NOT sent to backend)
        let requestId = UUID().uuidString
        currentRequestId = requestId

        print("========== [WebSocket] sendTextMessage TRIGGERED ==========")
        print("[WebSocket] request_id (local only): \(requestId)")

        let prepData: [String: Any] = [
            "user_prompt": [
                "scene": "交谈场景",
                "intention": "请综合语音、表情和生命体征，判断用户当前压力与情绪状态。",
                "analysis": "输出结构化结果，包含情绪标签、强度，以及是否需要干预的建议。"
            ]
        ]

        // Match client.py format EXACTLY - NO request_id field!
        let payload: [String: Any] = [
            "user_id": "11",
            "messages": [
                ["role": "user", "content": "你好"]
            ],
            "prep_data": prepData,
            "snapshot_window_sec": 15,
            "is_last": false
        ]

        print("[WebSocket] Payload keys: \(payload.keys.sorted())")

        sendMessage(messageType: "text", payload: payload)

        // Transition to triggered state
        connectionState = .triggered
        onTriggered?(requestId)
    }

    func sendVideoFrame(data: Data, timestamp: String, frameIndex: Int, width: Int, height: Int) {
        guard connectionState.canSendMedia else {
            return  // Silently drop - don't flood logs
        }

        // Check queue capacity before encoding
        let base64Data = data.base64EncodedString()
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "frame_index": frameIndex,
            "codec": "H264",
            "width": width,
            "height": height,
            "data": base64Data,
            "size": data.count
        ]

        // Create message and enqueue
        guard let jsonString = serializeToJSON(payload) else {
            return
        }

        let message = StreamMessage(
            type: .video,
            payload: jsonString.data(using: .utf8)!,
            metadata: [
                "messageType": "video",
                "frameIndex": frameIndex
            ]
        )

        _ = streamQueue.enqueueVideo(message)
    }

    func sendAudioChunk(data: Data, timestamp: String, chunkIndex: Int, sampleRate: Int, channels: Int) {
        guard connectionState.canSendMedia else {
            return  // Silently drop
        }

        let base64Data = data.base64EncodedString()
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "chunk_index": chunkIndex,
            "codec": "AAC",
            "sample_rate": sampleRate,
            "channels": channels,
            "data": base64Data,
            "size": data.count
        ]

        guard let jsonString = serializeToJSON(payload) else {
            return
        }

        let message = StreamMessage(
            type: .audio,
            payload: jsonString.data(using: .utf8)!,
            metadata: [
                "messageType": "audio",
                "chunkIndex": chunkIndex
            ]
        )

        _ = streamQueue.enqueueAudio(message)
    }

    func sendVitalData(heartRate: Double, breathRate: Double, breathAmp: Double, conf: Double) {
        guard connectionState.canSendMedia else {
            return  // Silently drop
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "heart_rate": heartRate,
            "breath_rate": breathRate,
            "breath_amp": breathAmp,
            "conf": conf,
            "init_stat": 1,
            "presence_status": 1
        ]

        guard let jsonString = serializeToJSON(payload) else {
            return
        }

        let message = StreamMessage(
            type: .vital,
            payload: jsonString.data(using: .utf8)!,
            metadata: ["messageType": "vital"]
        )

        _ = streamQueue.enqueueVital(message)
    }

    // MARK: - Private Methods

    /// Safely serialize dictionary to JSON string, filtering out unsupported types
    /// Handles nested dictionaries and arrays recursively
    private func serializeToJSON(_ dict: [String: Any]) -> String? {
        let safeDict = filterSerializable(dict)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: safeDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }

    /// Recursively filter dictionary to only include serializable types
    private func filterSerializable(_ value: Any) -> Any {
        if let stringValue = value as? String {
            return stringValue
        } else if let intValue = value as? Int {
            return intValue
        } else if let doubleValue = value as? Double {
            return doubleValue
        } else if let boolValue = value as? Bool {
            return boolValue
        } else if value is NSNull {
            return NSNull()
        } else if let dict = value as? [String: Any] {
            // Recursively filter dictionary
            var safeDict: [String: Any] = [:]
            for (key, val) in dict {
                safeDict[key] = filterSerializable(val)
            }
            return safeDict
        } else if let array = value as? [Any] {
            // Recursively filter array
            return array.map { filterSerializable($0) }
        }
        // Skip Data, Date, and other unsupported types
        return NSNull()
    }

    private func setupStreamQueue() {
        // Configure queue from AppConfig
        var config = StreamQueueManager.Config()
        config.maxVideoQueueSize = AppConfig.Queue.maxVideoQueueSize
        config.maxAudioQueueSize = AppConfig.Queue.maxAudioQueueSize
        config.maxVitalQueueSize = AppConfig.Queue.maxVitalQueueSize
        config.sendIntervalMs = AppConfig.Queue.sendIntervalMs
        config.dropAudioWhenFull = AppConfig.Queue.dropAudioWhenFull
        streamQueue.configure(config)

        streamQueue.onSendMessage = { [weak self] message in
            self?.sendStreamMessage(message)
        }

        // Update queue stats periodically
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.queueStats = self?.streamQueue.stats ?? StreamQueueStats()
        }
    }

    private func sendMessage(messageType: String, payload: Any) {
        guard let webSocketTask = webSocketTask else {
            streamQueue.recordSendError("No WebSocket task")
            return
        }

        // Check task state
        guard webSocketTask.state == .running else {
            streamQueue.recordSendError("Task not running: \(webSocketTask.state.rawValue)")
            return
        }

        let message: [String: Any] = [
            "message_type": messageType,
            "payload": payload
        ]

        guard let jsonString = serializeToJSON(message) else {
            return
        }

        // Print detailed info for text messages
        if messageType == "text" {
            print("[WebSocket] ====== TEXT MESSAGE BEING SENT ======")
            print("[WebSocket] Full JSON: \(jsonString)")
        } else {
            print("[WebSocket] Sending message_type: \(messageType)")
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.streamQueue.recordSendError(error.localizedDescription)
            }
        }
    }

    private func sendStreamMessage(_ streamMessage: StreamMessage) {
        let messageType = streamMessage.metadata["messageType"] as? String ?? "unknown"

        guard let webSocketTask = webSocketTask else {
            streamQueue.recordSendError("No WebSocket task")
            return
        }

        guard webSocketTask.state == .running else {
            streamQueue.recordSendError("Task not running: \(webSocketTask.state.rawValue)")
            return
        }

        // Convert JSON payload Data back to string (it was stored as JSON string)
        guard let payloadString = String(data: streamMessage.payload, encoding: .utf8) else {
            streamQueue.recordSendError("Failed to decode payload")
            return
        }

        // Parse the JSON string back to object
        guard let payloadData = payloadString.data(using: .utf8),
              let payloadJson = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            streamQueue.recordSendError("Failed to parse payload JSON")
            return
        }

        // Build wrapper - payload should be JSON object, NOT base64 string (matching client.py)
        let wrapper: [String: Any] = [
            "message_type": messageType,
            "payload": payloadJson
        ]

        guard let jsonString = serializeToJSON(wrapper) else {
            return
        }

        if messageType == "video" || messageType == "audio" || messageType == "vital" {
            print("[WebSocket] \(messageType) payload (no double base64): \(payloadString.prefix(100))...")
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.streamQueue.recordSendError(error.localizedDescription)
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            self?.handleReceiveResult(result)
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                handleTextMessage(text)
            case .data(let data):
                if let string = String(data: data, encoding: .utf8) {
                    handleTextMessage(string)
                }
            @unknown default:
                break
            }

            // Continue receiving if still connected
            if connectionState.isActive {
                receiveMessage()
            }

        case .failure(let error):
            handleDisconnection(error: error)
        }
    }

    // Background queue for message processing
    private let processingQueue = DispatchQueue(label: "com.emora.messageProcessing", qos: .userInitiated)

    private func handleTextMessage(_ string: String) {
        // Deduplication: check if we've seen this message
        let messageHash = String(string.hashValue)
        var shouldSkip = false

        seenMessagesLock.lock()
        if seenMessageHashes.contains(messageHash) {
            shouldSkip = true
        } else {
            if seenMessageHashes.count >= maxSeenMessages {
                seenMessageHashes.removeFirst()
            }
            seenMessageHashes.insert(messageHash)
        }
        seenMessagesLock.unlock()

        if shouldSkip {
            return
        }

        // Store raw response immediately for UI
        lastResponse = string

        // Move heavy processing to background queue
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // Append response in background
            self.responses.append(string)

            // Parse JSON in background
            guard let data = string.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            let messageType = json["message_type"] as? String ?? ""
            let payload = json["payload"] as? [String: Any]
            let isFinal = json["is_final"] as? Bool ?? false
            let requestId = json["request_id"] as? String ?? ""

            // Handle state changes on main thread
            DispatchQueue.main.async {
                switch messageType {
                case "ack":
                    if self.connectionState == .transportConnected {
                        self.connectionState = .appReady
                        self.onAppReady?()
                    }

                case "chunk":
                    if isFinal {
                        if self.connectionState == .triggered {
                            self.connectionState = .streaming
                        }
                    }

                case "final":
                    if self.connectionState == .triggered {
                        self.connectionState = .streaming
                    }

                case "error":
                    let code = json["code"] as? Int ?? 0
                    let msg = json["msg"] as? String ?? ""
                    print("[WebSocket] Server error: code=\(code), msg=\(msg)")

                default:
                    break
                }
            }

            // Keep only last 100 responses (in background)
            if self.responses.count > 100 {
                self.responses.removeFirst()
            }
        }
    }

    private func handleDisconnection(error: Error?) {
        let wasConnected = connectionState.isActive
        connectionState = .disconnected
        stopHeartbeat()

        // Stop streaming
        streamQueue.stopSender()
        streamQueue.clearQueues()

        // Only attempt reconnect if it wasn't a user-initiated disconnect
        if wasConnected && !isUserDisconnected {
            attemptReconnect()
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendAppPing()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendAppPing() {
        let pingMessage: [String: Any] = [
            "message_type": "ping"
        ]

        guard let jsonString = serializeToJSON(pingMessage) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                print("[WebSocket] Ping failed: \(error.localizedDescription)")
                self?.attemptReconnect()
            }
        }
    }

    private func attemptReconnect() {
        guard !isUserDisconnected else { return }

        guard reconnectAttempt < maxReconnectAttempts else {
            connectionState = .failed("Max reconnection attempts reached")
            return
        }

        reconnectAttempt += 1
        connectionState = .failed("Reconnecting (\(reconnectAttempt)/\(maxReconnectAttempts))...")

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = pow(2.0, Double(reconnectAttempt - 1))
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, !self.isUserDisconnected else {
                return
            }
            self.connect()
        }
    }

    func clearResponses() {
        responses.removeAll()
        lastResponse = ""
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketManager {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        connectionState = .transportConnected
        reconnectAttempt = 0
        startHeartbeat()
        onConnected?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connectionState = .disconnected
        stopHeartbeat()

        if closeCode != .normalClosure && !isUserDisconnected {
            attemptReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            connectionState = .failed(error.localizedDescription)
            attemptReconnect()
        }
    }
}
