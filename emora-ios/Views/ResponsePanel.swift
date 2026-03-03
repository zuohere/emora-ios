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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formattedTime)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "9CA3AF"))

            Text(formattedResponse)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
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

    var body: some View {
        HStack {
            Text(truncatedResponse)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        ResponsePanel(viewModel: EmoraViewModel())
            .padding()
    }
}
