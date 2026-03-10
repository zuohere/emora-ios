import Foundation

// MARK: - App Configuration

struct AppConfig {
    // WebSocket Configuration
    static let webSocketBaseURL = "wss://api.finnox.cn/gateway/v1/proxy/ws"

    // Token should be set from secure storage or environment
    // DO NOT hardcode in production - use Keychain or secure storage
    static var authToken: String {
        // For development, read from environment or use placeholder
        // In production, use Keychain
        return ProcessInfo.processInfo.environment["EMORA_AUTH_TOKEN"] ?? "25942d659fd81c3a4faa8deae5d3e278.CwjYQzIEqF1uHX0f7EG9CiBfZN14qRimke4lixE9dzw"
    }

    // Queue Configuration
    struct Queue {
        static let maxVideoQueueSize = 30      // ~2 seconds at 15fps
        static let maxAudioQueueSize = 100     // ~200ms at 512 samples
        static let maxVitalQueueSize = 5       // ~10 seconds at 2s interval
        static let sendIntervalMs = 16         // ~60fps max send rate
        static let dropAudioWhenFull = true
    }

    // Video Configuration
    struct Video {
        static let width = 1280
        static let height = 720
        static let fps = 15
        static let bitrate = 1_000_000  // 1 Mbps
    }

    // Audio Configuration
    struct Audio {
        static let sampleRate = 24000
        static let channels = 1
        static let chunkSize = 512
        static let bitrate = 64000  // 64 kbps AAC
    }

    // Reconnection Configuration
    struct Reconnection {
        static let maxAttempts = 5
        static let baseDelaySeconds = 1.0
    }

    // Heartbeat Configuration
    struct Heartbeat {
        static let intervalSeconds = 30
    }
}
