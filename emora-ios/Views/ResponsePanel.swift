import SwiftUI

// MARK: - Response Panel

struct ResponsePanel: View {
    @ObservedObject var viewModel: EmoraViewModel

    // Colors from SPEC
    private let surfaceColor = Color(hex: "1F2937")

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if !viewModel.responses.isEmpty {
                    Text("\(viewModel.responses.count) messages")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "9CA3AF"))

                    Button(action: {
                        viewModel.clearResponses()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "9CA3AF"))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(surfaceColor)

            // History content - always visible now
            if viewModel.responses.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "message")
                        .font(.system(size: 24))
                        .foregroundColor(Color(hex: "6B7280"))

                    Text("No messages yet")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "6B7280"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 100)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(viewModel.responses.enumerated()), id: \.offset) { index, response in
                                ResponseItem(response: response, isExpanded: expandedItems.contains(index))
                                    .id(index)
                                    .highPriorityGesture(
                                        TapGesture().onEnded {
                                            withAnimation(.spring(response: 0.3)) {
                                                if expandedItems.contains(index) {
                                                    expandedItems.remove(index)
                                                } else {
                                                    expandedItems.insert(index)
                                                }
                                            }
                                        }
                                    )
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
                .frame(height: 100)
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

    @State private var expandedItems: Set<Int> = []
}

// MARK: - Response Item

struct ResponseItem: View {
    let response: String
    var isExpanded: Bool = false
    @State private var parsedEmotionResult: EmotionAnalysisResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formattedTime)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "9CA3AF"))

                Spacer()

                if parsedEmotionResult != nil {
                    Text("Emotion")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "8B5CF6"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: "8B5CF6").opacity(0.2))
                        )
                }

                // Expand indicator
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "6B7280"))
            }

            if let emotionResult = parsedEmotionResult {
                // Show emotion result (compact when collapsed, full when expanded)
                if isExpanded {
                    EmotionResultView(result: emotionResult)
                } else {
                    CompactEmotionPreview(result: emotionResult)
                }
            } else {
                // Show regular text response
                Text(isExpanded ? fullResponse : truncatedResponse)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(isExpanded ? nil : 2)
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

    private var truncatedResponse: String {
        // Try to format JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            return String(response.prefix(100))
        }

        switch messageType {
        case "chunk":
            if let payload = json["payload"] as? [String: Any] {
                if let delta = payload["delta"] as? String {
                    return String(delta.prefix(100))
                }
                if payload["emotion_result"] != nil {
                    return "Emotion analysis result"
                }
            }
            return "Chunk received"
        case "ack":
            return "Acknowledged"
        default:
            return String(response.prefix(100))
        }
    }

    private var fullResponse: String {
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
                if let emotionResult = payload["emotion_result"] as? [String: Any] {
                    // Manually format the emotion result instead of re-serializing
                    if let emotion = emotionResult["emotion"] as? [String: Any],
                       let emotionLabel = emotion["emotion_label"] as? String {
                        return "Emotion: \(emotionLabel)"
                    }
                    // Fallback: show as string
                    return String(describing: emotionResult)
                }
            }
            return "Chunk received"
        case "ack":
            // Show full acknowledgment details
            if let payload = json["payload"] as? [String: Any] {
                var details: [String] = []
                if let type = payload["type"] as? String {
                    details.append("Type: \(type)")
                }
                if let message = payload["message"] as? String {
                    details.append("Message: \(message)")
                }
                if let timestamp = payload["timestamp"] as? Double {
                    let date = Date(timeIntervalSince1970: timestamp)
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .medium
                    details.append("Time: \(formatter.string(from: date))")
                }
                return details.isEmpty ? "Acknowledged" : details.joined(separator: "\n")
            }
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
