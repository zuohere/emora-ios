import SwiftUI

// MARK: - Emotion Analysis Result Model

struct EmotionAnalysisResult: Codable {
    let sessionId: String
    let emotion: EmotionData
    let intention: IntentionData
    let success: Bool
    let error: String?
    let processingTime: Double
    let tokenUsage: TokenUsage?
    let latestTimestamp: Double
    let windowSec: Double

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case emotion
        case intention
        case success
        case error
        case processingTime = "processing_time"
        case tokenUsage = "token_usage"
        case latestTimestamp = "latest_timestamp"
        case windowSec = "window_sec"
    }
}

struct EmotionData: Codable {
    let emotion: EmotionScores
    let analysis: String
    let confidence: Double
}

struct EmotionScores: Codable {
    let happy: Double
    let surprised: Double
    let angry: Double
    let disgusted: Double
    let sad: Double
    let fearful: Double
    let neutral: Double

    var sortedEmotions: [(name: String, value: Double, color: String)] {
        [
            ("happy", happy, "4CAF50"),
            ("surprised", surprised, "FFC107"),
            ("angry", angry, "F44336"),
            ("disgusted", disgusted, "8BC34A"),
            ("sad", sad, "2196F3"),
            ("fearful", fearful, "9C27B0"),
            ("neutral", neutral, "9E9E9E")
        ].sorted { $0.value > $1.value }
    }

    var dominantEmotion: (name: String, value: Double, color: String) {
        sortedEmotions.first ?? ("neutral", 0.0, "9E9E9E")
    }
}

struct IntentionData: Codable {
    let detectedIntentions: [DetectedIntention]
    let recommendedContent: RecommendedContent
    let contextAnalysis: ContextAnalysis

    enum CodingKeys: String, CodingKey {
        case detectedIntentions = "detected_intentions"
        case recommendedContent = "recommended_content"
        case contextAnalysis = "context_analysis"
    }
}

struct DetectedIntention: Codable {
    let type: String
    let confidence: Double
    let reasoning: String
}

struct RecommendedContent: Codable {
    let suggestion: String
    let action: String
}

struct ContextAnalysis: Codable {
    let keyFactors: [String]
    let confidenceLevel: Double
    let userPrompt: String

    enum CodingKeys: String, CodingKey {
        case keyFactors = "key_factors"
        case confidenceLevel = "confidence_level"
        case userPrompt = "user_prompt"
    }
}

struct TokenUsage: Codable {
    let emotion: TokenDetail
    let intention: TokenDetail
}

struct TokenDetail: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - Emotion Result View

struct EmotionResultView: View {
    let result: EmotionAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with dominant emotion
            EmotionHeaderView(result: result)

            Divider()
                .background(Color.white.opacity(0.2))

            // Emotion scores bars
            EmotionBarsView(emotion: result.emotion.emotion)

            // Analysis text
            AnalysisSectionView(analysis: result.emotion.analysis, confidence: result.emotion.confidence)

            // Intention detection
            if !result.intention.detectedIntentions.isEmpty {
                IntentionSectionView(intention: result.intention)
            }

            // Recommended action
            RecommendedActionView(recommendation: result.intention.recommendedContent)

            // Footer with processing info
            FooterInfoView(result: result)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "1F2937"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(emotionBorderColor, lineWidth: 2)
        )
    }

    private var emotionBorderColor: Color {
        let dominant = result.emotion.emotion.dominantEmotion
        return Color(hex: dominant.color).opacity(0.6)
    }
}

// MARK: - Header

struct EmotionHeaderView: View {
    let result: EmotionAnalysisResult

    private var dominantEmotion: (name: String, value: Double, color: String) {
        result.emotion.emotion.dominantEmotion
    }

    var body: some View {
        HStack {
            // Emotion icon with glow
            ZStack {
                Circle()
                    .fill(Color(hex: dominantEmotion.color).opacity(0.2))
                    .frame(width: 56, height: 56)

                Circle()
                    .fill(Color(hex: dominantEmotion.color).opacity(0.4))
                    .frame(width: 44, height: 44)

                Image(systemName: emotionIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: dominantEmotion.color))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(emotionNameCN)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text("Confidence: \(Int(result.emotion.confidence * 100))%")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "9CA3AF"))
            }

            Spacer()

            // Processing time badge
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(String(format: "%.2f", result.processingTime))s")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "6366F1"))

                Text("Processing")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "9CA3AF"))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "6366F1").opacity(0.2))
            )
        }
    }

    private var emotionIcon: String {
        switch dominantEmotion.name {
        case "happy": return "face.smiling"
        case "surprised": return "face.smiling.inverse"
        case "angry": return "face.angry"
        case "disgusted": return "face.dizzy"
        case "sad": return "face.sad"
        case "fearful": return "face.awesome"
        default: return "face.smiling"
        }
    }

    private var emotionNameCN: String {
        switch dominantEmotion.name {
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

// MARK: - Emotion Bars

struct EmotionBarsView: View {
    let emotion: EmotionScores

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("情绪分布")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            ForEach(emotion.sortedEmotions.prefix(5), id: \.name) { item in
                EmotionBarRow(item: item)
            }
        }
    }
}

struct EmotionBarRow: View {
    let item: (name: String, value: Double, color: String)

    private var nameCN: String {
        switch item.name {
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
        HStack(spacing: 12) {
            Text(nameCN)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "9CA3AF"))
                .frame(width: 40, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: item.color))
                        .frame(width: geometry.size.width * item.value, height: 8)
                }
            }
            .frame(height: 8)

            Text("\(Int(item.value * 100))%")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: item.color))
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Analysis Section

struct AnalysisSectionView: View {
    let analysis: String
    let confidence: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "8B5CF6"))

                Text("分析结果")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            Text(analysis)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineSpacing(4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "8B5CF6").opacity(0.1))
        )
    }
}

// MARK: - Intention Section

struct IntentionSectionView: View {
    let intention: IntentionData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "06B6D4"))

                Text("意图识别")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            ForEach(intention.detectedIntentions.prefix(2), id: \.type) { item in
                IntentionItemView(item: item)
            }
        }
    }
}

struct IntentionItemView: View {
    let item: DetectedIntention

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.type)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "06B6D4"))

                Spacer()

                Text("\(Int(item.confidence * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "06B6D4").opacity(0.8))
            }

            Text(item.reasoning)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "9CA3AF"))
                .lineLimit(3)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "06B6D4").opacity(0.1))
        )
    }
}

// MARK: - Recommended Action

struct RecommendedActionView: View {
    let recommendation: RecommendedContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "F59E0B"))

                Text("建议")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            Text(recommendation.suggestion)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))

            Text(recommendation.action)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "9CA3AF"))
                .italic()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color(hex: "F59E0B").opacity(0.15), Color(hex: "F59E0B").opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
    }
}

// MARK: - Footer Info

struct FooterInfoView: View {
    let result: EmotionAnalysisResult

    var body: some View {
        HStack {
            // Session ID
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 10))
                Text(result.sessionId.prefix(8) + "...")
                    .font(.system(size: 10))
            }
            .foregroundColor(Color(hex: "6B7280"))

            Spacer()

            // Token usage
            if let tokenUsage = result.tokenUsage {
                HStack(spacing: 8) {
                    Text("Tokens: \(tokenUsage.emotion.totalTokens + tokenUsage.intention.totalTokens)")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "6B7280"))
                }
            }

            // Window info
            Text("Window: \(Int(result.windowSec))s")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "6B7280"))
        }
        .padding(.top, 4)
    }
}

// MARK: - Parser Helper

extension EmotionAnalysisResult {
    static func parse(from jsonString: String) -> EmotionAnalysisResult? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        // Try to extract emotion_result from the payload
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any],
           let emotionResult = payload["emotion_result"] {

            if let resultData = try? JSONSerialization.data(withJSONObject: emotionResult),
               let result = try? JSONDecoder().decode(EmotionAnalysisResult.self, from: resultData) {
                return result
            }
        }

        // Try direct parsing
        return try? JSONDecoder().decode(EmotionAnalysisResult.self, from: data)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        let sampleJSON = """
        {
          "session_id": "a3732c12-4821-449b-818a-6c2502058014",
          "emotion": {
            "emotion": {
              "happy": 0.0,
              "surprised": 0.0,
              "angry": 0.0,
              "disgusted": 0.0,
              "sad": 0.085,
              "fearful": 0.005,
              "neutral": 0.91
            },
            "analysis": "情绪标签为中性，强度较高；无需干预",
            "confidence": 0.85
          },
          "intention": {
            "detected_intentions": [
              {
                "type": "情绪状态较为放松，压力较低",
                "confidence": 0.8,
                "reasoning": "从表情来看，大部分时间处于中性且悲伤情绪占比低，生命体征方面心率、呼吸率等处于相对平稳状态，综合判断用户当前压力较低，情绪较为放松"
              }
            ],
            "recommended_content": {
              "suggestion": "可以继续保持当前轻松的状态，继续进行自然的交流互动",
              "action": "维持当前舒适的交谈氛围，不刻意制造压力情境"
            },
            "context_analysis": {
              "key_factors": ["数据不足"],
              "confidence_level": 0.0,
              "user_prompt": "未知"
            },
            "question_answer": "无法基于当前数据回答问题"
          },
          "success": true,
          "error": null,
          "processing_time": 1.74,
          "token_usage": {
            "emotion": {
              "prompt_tokens": 981,
              "completion_tokens": 120,
              "total_tokens": 1101
            },
            "intention": {
              "prompt_tokens": 869,
              "completion_tokens": 145,
              "total_tokens": 1014
            }
          },
          "latest_timestamp": 1772547878.055733,
          "window_sec": 15.0
        }
        """

        if let result = EmotionAnalysisResult.parse(from: sampleJSON) {
            EmotionResultView(result: result)
                .padding()
        }
    }
}
