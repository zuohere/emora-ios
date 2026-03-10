import Foundation
import Combine

// MARK: - Stream Message Types

enum StreamMessageType: String, Codable {
    case video
    case audio
    case vital
    case text
}

// MARK: - Stream Message

struct StreamMessage {
    let id: UUID
    let type: StreamMessageType
    let payload: Data
    let timestamp: Date
    let metadata: [String: Any]

    init(type: StreamMessageType, payload: Data, metadata: [String: Any] = [:]) {
        self.id = UUID()
        self.type = type
        self.payload = payload
        self.timestamp = Date()
        self.metadata = metadata
    }
}

// MARK: - Queue Statistics

struct StreamQueueStats {
    var videoQueueLength: Int = 0
    var audioQueueLength: Int = 0
    var vitalQueueLength: Int = 0
    var videoDropCount: Int = 0
    var audioDropCount: Int = 0
    var vitalDropCount: Int = 0
    var videoSendLatencyMs: Double = 0
    var audioSendLatencyMs: Double = 0
    var lastSendError: String = ""
    var isSenderRunning: Bool = false

    var totalQueueLength: Int {
        videoQueueLength + audioQueueLength + vitalQueueLength
    }

    var totalDropCount: Int {
        videoDropCount + audioDropCount + vitalDropCount
    }
}

// MARK: - Stream Queue Manager

final class StreamQueueManager: ObservableObject {
    // MARK: - Singleton

    static let shared = StreamQueueManager()

    // MARK: - Configuration

    struct Config {
        var maxVideoQueueSize: Int = 30       // ~2 seconds at 15fps
        var maxAudioQueueSize: Int = 100      // ~200ms at 512 samples
        var maxVitalQueueSize: Int = 5        // ~10 seconds at 2s interval
        var sendIntervalMs: Int = 16          // ~60fps max send rate
        var dropAudioWhenFull: Bool = true    // Drop audio packets when queue full
    }

    // MARK: - Published Properties

    @Published private(set) var stats = StreamQueueStats()

    // MARK: - Properties

    private var config = Config()

    // Ring buffers (using arrays with index tracking for simplicity)
    private var videoQueue: [StreamMessage] = []
    private var audioQueue: [StreamMessage] = []
    private var vitalQueue: [StreamMessage] = []

    // Queue locks
    private let videoQueueLock = NSLock()
    private let audioQueueLock = NSLock()
    private let vitalQueueLock = NSLock()

    // Serial sender
    private var senderTimer: Timer?
    private var isSenderRunning = false
    private let senderQueue = DispatchQueue(label: "com.emora.streamSender")

    // Callback for sending through WebSocket
    var onSendMessage: ((StreamMessage) -> Void)?

    // Latency tracking
    private var sendTimestamps: [UUID: Date] = [:]
    private let latencyLock = NSLock()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Configure queue sizes
    func configure(_ config: Config) {
        self.config = config
    }

    /// Start the serial sender
    func startSender() {
        guard !isSenderRunning else { return }

        DispatchQueue.main.async { [weak self] in
            self?.isSenderRunning = true
            self?.stats.isSenderRunning = true
        }

        // Use timer on main thread for simplicity
        senderTimer = Timer.scheduledTimer(
            withTimeInterval: Double(config.sendIntervalMs) / 1000.0,
            repeats: true
        ) { [weak self] _ in
            self?.processNextMessage()
        }
    }

    /// Stop the serial sender
    func stopSender() {
        senderTimer?.invalidate()
        senderTimer = nil

        DispatchQueue.main.async { [weak self] in
            self?.isSenderRunning = false
            self?.stats.isSenderRunning = false
        }
    }

    /// Clear all queues
    func clearQueues() {
        videoQueueLock.lock()
        videoQueue.removeAll()
        videoQueueLock.unlock()

        audioQueueLock.lock()
        audioQueue.removeAll()
        audioQueueLock.unlock()

        vitalQueueLock.lock()
        vitalQueue.removeAll()
        vitalQueueLock.unlock()

        updateStats()
    }

    // MARK: - Enqueue Methods

    /// Enqueue a video frame
    /// Returns: true if enqueued, false if dropped
    @discardableResult
    func enqueueVideo(_ message: StreamMessage) -> Bool {
        videoQueueLock.lock()
        defer { videoQueueLock.unlock() }

        if videoQueue.count >= config.maxVideoQueueSize {
            // Drop oldest frame (ring buffer behavior)
            videoQueue.removeFirst()
            stats.videoDropCount += 1

            // Still add the new frame
            videoQueue.append(message)
            return true
        }

        videoQueue.append(message)
        return true
    }

    /// Enqueue an audio chunk
    /// Returns: true if enqueued, false if dropped
    @discardableResult
    func enqueueAudio(_ message: StreamMessage) -> Bool {
        audioQueueLock.lock()
        defer { audioQueueLock.unlock() }

        if audioQueue.count >= config.maxAudioQueueSize {
            if config.dropAudioWhenFull {
                // Drop oldest packet
                audioQueue.removeFirst()
                stats.audioDropCount += 1
            } else {
                // Queue full, drop new packet
                return false
            }
        }

        audioQueue.append(message)
        return true
    }

    /// Enqueue vital data
    /// Returns: true if enqueued, false if dropped
    @discardableResult
    func enqueueVital(_ message: StreamMessage) -> Bool {
        vitalQueueLock.lock()
        defer { vitalQueueLock.unlock() }

        if vitalQueue.count >= config.maxVitalQueueSize {
            // Drop oldest
            vitalQueue.removeFirst()
            stats.vitalDropCount += 1
        }

        vitalQueue.append(message)
        return true
    }

    // MARK: - Private Methods

    private func processNextMessage() {
        senderQueue.async { [weak self] in
            guard let self = self else { return }

            // Priority: video > audio > vital
            var message: StreamMessage?

            // Try video first
            self.videoQueueLock.lock()
            if !self.videoQueue.isEmpty {
                message = self.videoQueue.removeFirst()
            }
            self.videoQueueLock.unlock()

            // Then audio
            if message == nil {
                self.audioQueueLock.lock()
                if !self.audioQueue.isEmpty {
                    message = self.audioQueue.removeFirst()
                }
                self.audioQueueLock.unlock()
            }

            // Then vital
            if message == nil {
                self.vitalQueueLock.lock()
                if !self.vitalQueue.isEmpty {
                    message = self.vitalQueue.removeFirst()
                }
                self.vitalQueueLock.unlock()
            }

            // Send if we have a message
            if let msg = message {
                // Track latency
                self.latencyLock.lock()
                self.sendTimestamps[msg.id] = msg.timestamp
                self.latencyLock.unlock()

                // Update stats before sending
                self.updateStats()

                // Send via callback
                self.onSendMessage?(msg)

                // Calculate latency after send
                self.latencyLock.lock()
                if let sendTime = self.sendTimestamps.removeValue(forKey: msg.id) {
                    let latencyMs = Date().timeIntervalSince(sendTime) * 1000
                    switch msg.type {
                    case .video:
                        self.stats.videoSendLatencyMs = latencyMs
                    case .audio:
                        self.stats.audioSendLatencyMs = latencyMs
                    default:
                        break
                    }
                }
                self.latencyLock.unlock()
            }

            // Update stats after processing
            self.updateStats()
        }
    }

    private func updateStats() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.videoQueueLock.lock()
            self.stats.videoQueueLength = self.videoQueue.count
            self.videoQueueLock.unlock()

            self.audioQueueLock.lock()
            self.stats.audioQueueLength = self.audioQueue.count
            self.audioQueueLock.unlock()

            self.vitalQueueLock.lock()
            self.stats.vitalQueueLength = self.vitalQueue.count
            self.vitalQueueLock.unlock()
        }
    }

    /// Record a send error
    func recordSendError(_ error: String) {
        DispatchQueue.main.async { [weak self] in
            self?.stats.lastSendError = error
        }
    }
}
