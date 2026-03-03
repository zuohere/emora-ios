import Foundation

// MARK: - WebSocket Message Models

struct WebSocketMessage: Codable {
    let messageType: String
    let payload: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case payload
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Video Payload

struct VideoPayload: Codable {
    let timestamp: String
    let frameIndex: Int
    let codec: String
    let width: Int
    let height: Int
    let data: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case timestamp
        case frameIndex = "frame_index"
        case codec
        case width
        case height
        case data
        case size
    }
}

// MARK: - Audio Payload

struct AudioPayload: Codable {
    let timestamp: String
    let chunkIndex: Int
    let codec: String
    let sampleRate: Int
    let channels: Int
    let data: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case timestamp
        case chunkIndex = "chunk_index"
        case codec
        case sampleRate = "sample_rate"
        case channels
        case data
        case size
    }
}

// MARK: - Text Payload (for "s" request)

struct TextPayload: Codable {
    let userId: String
    let messages: [MessageContent]
    let prepData: PrepData
    let snapshotWindowSec: Double
    let isLast: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case messages
        case prepData = "prep_data"
        case snapshotWindowSec = "snapshot_window_sec"
        case isLast = "is_last"
    }
}

struct MessageContent: Codable {
    let role: String
    let content: String
}

struct PrepData: Codable {
    let userPrompt: UserPrompt

    enum CodingKeys: String, CodingKey {
        case userPrompt = "user_prompt"
    }
}

struct UserPrompt: Codable {
    let scene: String
    let intention: String
    let analysis: String
}

// MARK: - Vital Payload

struct VitalPayload: Codable {
    let timestamp: String
    let heartRate: Double
    let breathRate: Double
    let breathAmp: Double
    let conf: Double
    let initStat: Int
    let presenceStatus: Int

    enum CodingKeys: String, CodingKey {
        case timestamp
        case heartRate = "heart_rate"
        case breathRate = "breath_rate"
        case breathAmp = "breath_amp"
        case conf
        case initStat = "init_stat"
        case presenceStatus = "presence_status"
    }
}

// MARK: - Response Models

struct ChunkResponse: Codable {
    let messageType: String
    let requestId: String?
    let payload: ChunkPayload?
    let seq: Int?
    let isFinal: Bool?
    let tokenUsage: Int?
    let timeUsage: Double?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case requestId = "request_id"
        case payload
        case seq
        case isFinal = "is_final"
        case tokenUsage = "token_usage"
        case timeUsage = "time_usage"
    }
}

struct ChunkPayload: Codable {
    let delta: String?
    let emotionResult: EmotionResult?

    enum CodingKeys: String, CodingKey {
        case delta
        case emotionResult = "emotion_result"
    }
}

struct EmotionResult: Codable {
    // Add fields based on actual backend response
    // This is a placeholder structure
    let labels: [String]?
    let intensity: Double?
    let suggestion: String?
}
