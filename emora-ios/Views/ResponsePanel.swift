import SwiftUI

// MARK: - Response Panel

struct ResponsePanel: View {
    @ObservedObject var viewModel: EmoraViewModel
    @State private var isExpanded: Bool = false

    // Colors from SPEC
    private let surfaceColor = Color(hex: "1F2937")

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Analysis Response")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if !viewModel.responses.isEmpty {
                    Button(action: {
                        viewModel.clearResponses()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "9CA3AF"))
                    }
                }

                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "9CA3AF"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(surfaceColor)

            // Content
            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(viewModel.responses.enumerated()), id: \.offset) { index, response in
                                ResponseItem(response: response)
                                    .id(index)
                            }
                        }
                        .padding(16)
                    }
                    .background(Color.black.opacity(0.3))
                    .onChange(of: viewModel.responses.count) { _, _ in
                        if let lastIndex = viewModel.responses.indices.last {
                            withAnimation {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(height: 200)
            }

            // Latest response preview
            if !isExpanded && !viewModel.latestResponse.isEmpty {
                LatestResponsePreview(response: viewModel.latestResponse)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(surfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Response Item

struct ResponseItem: View {
    let response: String
    @State private var parsedEmotionResult: EmotionAnalysisResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formattedTime)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "9CA3AF"))

                Spacer()

                if parsedEmotionResult != nil {
                    Text("Emotion Analysis")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "8B5CF6"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: "8B5CF6").opacity(0.2))
                        )
                }
            }

            if let emotionResult = parsedEmotionResult {
                // Show beautiful emotion result view
                EmotionResultView(result: emotionResult)
            } else {
                // Show regular text response
                Text(formattedResponse)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(parsedEmotionResult != nil ? Color.clear : Color.white.opacity(0.05))
        )
        .onAppear {
            parseEmotionResult()
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }

    private func parseEmotionResult() {
        parsedEmotionResult = EmotionAnalysisResult.parse(from: response)
    }

    private var formattedResponse: String {
        // Try to format JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            return response
        }

        switch messageType {
        case "chunk":
            if let payload = json["payload"] as? [String: Any] {
                if let delta = payload["delta"] as? String {
                    return delta
                }
                if let emotionResult = payload["emotion_result"] {
                    if let resultData = try? JSONSerialization.data(withJSONObject: emotionResult, options: .prettyPrinted),
                       let resultString = String(data: resultData, encoding: .utf8) {
                        return resultString
                    }
                }
            }
            return "Chunk received"
        case "ack":
            return "Acknowledged"
        default:
            return response
        }
    }
}

// MARK: - Latest Response Preview

struct LatestResponsePreview: View {
    let response: String
    @State private var emotionResult: EmotionAnalysisResult?

    var body: some View {
        HStack {
            if let result = emotionResult {
                // Show compact emotion preview
                CompactEmotionPreview(result: result)
            } else {
                Text(truncatedResponse)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear {
            emotionResult = EmotionAnalysisResult.parse(from: response)
        }
    }

    private var truncatedResponse: String {
        // Extract meaningful content from response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else {
            return response.prefix(100).description
        }

        if let delta = payload["delta"] as? String {
            return delta
        }

        return payload.description.prefix(100).description
    }
}

// MARK: - Compact Emotion Preview

struct CompactEmotionPreview: View {
    let result: EmotionAnalysisResult

    private var dominant: (name: String, value: Double, color: String) {
        result.emotion.emotion.dominantEmotion
    }

    private var emotionNameCN: String {
        switch dominant.name {
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
        VStack(alignment: .leading, spacing: 8) {
            // Emotion status row
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: dominant.color))
                    .frame(width: 8, height: 8)

                Text(emotionNameCN)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Text("\(Int(dominant.value * 100))%")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "9CA3AF"))

                Text("·")
                    .foregroundColor(Color(hex: "6B7280"))

                Text(result.emotion.analysis.prefix(25) + (result.emotion.analysis.count > 25 ? "..." : ""))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "9CA3AF"))
                    .lineLimit(1)
            }

            // Intention row (if available)
            if let intention = result.intention.detectedIntentions.first {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "06B6D4"))

                    Text(intention.type.prefix(40) + (intention.type.count > 40 ? "..." : ""))
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "06B6D4"))
                        .lineLimit(1)

                    Spacer()
                }
            }

            // Recommendation row (if available)
            if !result.intention.recommendedContent.suggestion.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "F59E0B"))

                    Text(result.intention.recommendedContent.suggestion.prefix(50) + (result.intention.recommendedContent.suggestion.count > 50 ? "..." : ""))
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "F59E0B"))
                        .lineLimit(1)

                    Spacer()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        ResponsePanel(viewModel: EmoraViewModel())
            .padding()
    }
}
