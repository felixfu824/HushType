import SwiftUI

/// Card view displaying the source text and its translation.
struct TranslationCardView: View {
    let sourceLanguage: String
    let sourceText: String
    let translatedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: source language + clipboard confirmation
            HStack {
                Text(sourceLanguage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Divider()

            // Source text
            Text(sourceText)
                .font(.system(size: 16))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Translated text (scrollable for long content)
            ScrollView {
                Text(translatedText)
                    .font(.system(size: 22, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 380)

            // Footer
            HStack(alignment: .bottom) {
                Text("Esc to dismiss")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Powered by Apple Translation Framework. May connect to Apple servers.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(24)
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
