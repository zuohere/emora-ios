import Foundation
import Combine

// MARK: - Connection State

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt)/5)..."
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

// MARK: - WebSocket Manager

class WebSocketManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastResponse: String = ""
    @Published private(set) var responses: [String] = []

    // MARK: - Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 30

    // Flag to track if we've received server acknowledgment
    private var hasReceivedAck = false
    private var isUserDisconnected = false
    private let wsURL = "wss://api.finnox.cn/gateway/v1/proxy/ws?token=25942d659fd81c3a4faa8deae5d3e278.CwjYQzIEqF1uHX0f7EG9CiBfZN14qRimke4lixE9dzw" // Update with your backend URL

    // Callback for sending video/audio data
    var onConnected: (() -> Void)?

    // MARK: - Singleton

    static let shared = WebSocketManager()

    private override init() {
        super.init()
    }

    // MARK: - Public Methods

    func connect() {
        guard connectionState != .connected && connectionState != .connecting else {
            // print("[WebSocket] Already connected or connecting, skipping...")
            return
        }

        // Clean up existing connection without marking as user-initiated disconnect
        cleanupConnection()
        isUserDisconnected = false  // Reset flag for new connection
        connectionState = .connecting
        // print("[WebSocket] Connecting to \(wsURL)...")

        guard let url = URL(string: wsURL)else {
            connectionState = .failed("Invalid URL")
            // print("[WebSocket] FAILED - Invalid URL")
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true

        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        // print("[WebSocket] WebSocket task started, waiting for connection...")

        // Start receiving messages
        receiveMessage()
    }

    func disconnect() {
        // print("[WebSocket] Disconnecting...")
        isUserDisconnected = true  // Mark as user-initiated disconnect
        cleanupConnection()
        // print("[WebSocket] Disconnected")
    }

    /// Clean up existing connection without marking as user-initiated disconnect
    /// Used internally when reconnecting
    private func cleanupConnection() {
        stopHeartbeat()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
        reconnectAttempt = 0
        hasReceivedAck = false
    }

    // MARK: - Send Methods

    func sendTextMessage() {
        // Match client.py format exactly
        let prepData: [String: Any] = [
            "user_prompt": [
                "scene": "交谈场景",
                "intention": "请综合语音、表情和生命体征，判断用户当前压力与情绪状态。交谈场景，请综合语音、表情和生命体征，判断用户当前压力与情绪状态。",
                "analysis": "输出结构化结果，包含情绪标签、强度，以及是否需要干预的建议。"
            ]
        ]

        // Match client.py format - no top-level user_prompt
        let payload: [String: Any] = [
            "user_id": "11",
            "messages": [
                ["role": "user", "content": "你好，这是本地多模态情绪分析测试。"]
            ],
            "prep_data": prepData,
            "snapshot_window_sec": 15.0,
            "is_last": false
        ]

        sendMessage(messageType: "text", payload: payload)
    }

    func sendVideoFrame(data: Data, timestamp: String, frameIndex: Int, width: Int, height: Int) {
        //print("[WebSocket] sendVideoFrame: frameIndex=\(frameIndex), size=\(data.count)")
        let base64Data = data.base64EncodedString()
        // Note: client.py does NOT include user_id in video payload
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "frame_index": frameIndex,
            "codec": "H264",
            "width": width,
            "height": height,
            "data": base64Data,
            "size": data.count
        ]

        sendMessage(messageType: "video", payload: payload)
    }

    func sendAudioChunk(data: Data, timestamp: String, chunkIndex: Int, sampleRate: Int, channels: Int) {
        let base64Data = data.base64EncodedString()
        // Note: client.py does NOT include user_id in audio payload
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "chunk_index": chunkIndex,
            "codec": "AAC",
            "sample_rate": sampleRate,
            "channels": channels,
            "data": base64Data,
            "size": data.count
        ]

        sendMessage(messageType: "audio", payload: payload)
    }

    func sendVitalData(heartRate: Double, breathRate: Double, breathAmp: Double, conf: Double) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // Note: client.py does NOT include user_id in vital payload
        let payload: [String: Any] = [
            "timestamp": timestamp,
            "heart_rate": heartRate,
            "breath_rate": breathRate,
            "breath_amp": breathAmp,
            "conf": conf,
            "init_stat": 1,
            "presence_status": 1
        ]

        sendMessage(messageType: "vital", payload: payload)
    }

    // MARK: - Private Methods

    private func sendMessage(messageType: String, payload: Any) {
        guard let webSocketTask = webSocketTask else {
            //print("[WebSocket] Send FAILED - No WebSocket task, messageType: \(messageType)")
            return
        }

        // Check task state
        switch webSocketTask.state {
        case .running:
            break  // OK
        case .canceling:
            // print("[WebSocket] Send FAILED - Task is canceling, messageType: \(messageType)")
            return
        case .completed:
            // print("[WebSocket] Send FAILED - Task is completed, messageType: \(messageType)")
            return
        @unknown default:
            break
        }

        let message: [String: Any] = [
            "message_type": messageType,
            "payload": payload
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message)
            let messageSize = jsonData.count

            // Debug: Print exact JSON being sent
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                // print("\n========== [SENDING \(messageType.uppercased()) MESSAGE] ==========")
                // Pretty print for readability
                // if let prettyData = try? JSONSerialization.data(withJSONObject: message, options: [.prettyPrinted, .withoutEscapingSlashes]),
                //    let prettyString = String(data: prettyData, encoding: .utf8) {
                //     print(prettyString)
                // } else {
                //     print(jsonString)
                // }
                // print("===========================================================\n")

                let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask.send(wsMessage) { [weak self] error in
                    if let error = error {
                        // print("[WebSocket] Send FAILED - messageType: \(messageType), error: \(error.localizedDescription)")
                    } else {
                        // print("[WebSocket] Send SUCCESS - messageType: \(messageType), size: \(messageSize) bytes")
                    }
                }
            }
        } catch {
            // print("[WebSocket] Send FAILED - encode error: \(error.localizedDescription)")
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
            // Continue receiving
            if connectionState.isConnected {
                receiveMessage()
            }

        case .failure(let error):
            // print("[WebSocket] Receive error: \(error)")
            handleDisconnection(error: error)
        }
    }

    private func handleTextMessage(_ string: String) {
        lastResponse = string
        responses.append(string)

        // Parse JSON
        if let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Extract message type first
            let messageType = json["message_type"] as? String ?? ""

            // Only print for text response (chunk message)
            if messageType == "chunk" {
                print("\n==================================================")
                print("📥 [服务器返回的文本分析结果]")
                print("==================================================")

                if let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]),
                   let prettyString = String(data: prettyData, encoding: .utf8) {
                    print(prettyString)
                } else {
                    print(string)
                }
                print("==================================================\n")
            }

            // Extract key info (not printed)
            let payload = json["payload"] as? [String: Any]
            let isFinal = json["is_final"] as? Bool ?? false
            let seq = json["seq"] as? Int ?? 0
            let requestId = json["request_id"] as? String ?? ""

            if messageType == "chunk", let payload = payload {
                if let delta = payload["delta"] as? String {
                    // unused
                }
                if isFinal, let emotionResult = payload["emotion_result"] as? [String: Any] {
                    if let emotion = emotionResult["emotion"] as? [String: Any],
                       let analysis = emotionResult["analysis"] as? String {
                        // unused
                    }
                }
            } else if messageType == "ack" {
                // unused
            } else if messageType == "pong" {
                // unused
            } else if messageType == "error" {
                let code = json["code"] as? Int ?? 0
                let msg = json["msg"] as? String ?? ""
                // unused
            }
        } else {
            // Not JSON, print as is
            print(string)
        }
    

        // Keep only last 100 responses
        if responses.count > 100 {
            responses.removeFirst()
        }
    }

    private func handleDisconnection(error: Error?) {
        let wasConnected = connectionState == .connected
        connectionState = .disconnected
        stopHeartbeat()

        // print("[WebSocket] Disconnected - wasConnected: \(wasConnected), error: \(error?.localizedDescription ?? "nil"), userDisconnected: \(isUserDisconnected)")

        // Only attempt reconnect if it wasn't a user-initiated disconnect
        if wasConnected && !isUserDisconnected {
            attemptReconnect()
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            // print("[WebSocket] Sending application-layer ping...")
            self?.sendAppPing()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendAppPing() {
        // Send application-layer ping message (not WebSocket transport layer ping)
        let pingMessage: [String: Any] = [
            "message_type": "ping"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: pingMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                // print("[WebSocket] Ping send FAILED: \(error.localizedDescription)")
                self?.attemptReconnect()
            } else {
                // print("[WebSocket] Ping sent successfully")
            }
        }
    }

    private func attemptReconnect() {
        // Don't reconnect if user explicitly disconnected
        guard !isUserDisconnected else {
            // print("[WebSocket] Skipping reconnect - user disconnected")
            return
        }

        guard reconnectAttempt < maxReconnectAttempts else {
            connectionState = .failed("Max reconnection attempts reached")
            // print("[WebSocket] Max reconnection attempts reached")
            return
        }

        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        // print("[WebSocket] Reconnecting... attempt: \(reconnectAttempt)/\(maxReconnectAttempts)")

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = pow(2.0, Double(reconnectAttempt - 1))
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            // Check again before reconnecting
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

extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // print("[WebSocket] Connection OPENED - Handshake successful!")
        // Standard WebSocket: connection is ready when handshake completes
        connectionState = .connected
        hasReceivedAck = true  // Allow sending immediately after handshake
        reconnectAttempt = 0
        startHeartbeat()
        onConnected?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // print("[WebSocket] Connection CLOSED - closeCode: \(closeCode.rawValue)")
        connectionState = .disconnected
        stopHeartbeat()
        hasReceivedAck = false

        if closeCode != .normalClosure {
            // print("[WebSocket] Abnormal closure, attempting reconnect...")
            attemptReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // print("[WebSocket] Task completed with error: \(error.localizedDescription)")
            connectionState = .failed(error.localizedDescription)
            attemptReconnect()
        }
    }
}
