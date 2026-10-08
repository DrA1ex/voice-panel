import Foundation

public enum TranscriptTextNormalizer {
    private static let horizontalWhitespace = CharacterSet(charactersIn: " \t\u{00A0}")

    /// Only the recent tail is needed in the compact viewport. Bound the input
    /// before normalizing so audio-level updates never process the full session.
    public static func singleLinePreview(_ text: String, maximumCharacters: Int = 1_200) -> String {
        guard maximumCharacters > 0 else { return "" }
        let tail = String(text.suffix(maximumCharacters))
        let normalized = normalize(tail)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(normalized.suffix(maximumCharacters))
    }

    /// Normalizes spacing emitted by speech engines while preserving explicit
    /// line breaks. The return/new-line symbols used by some dictation engines
    /// are converted into real newlines.
    public static func normalize(_ text: String) -> String {
        var value =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "↵", with: "\n")
            .replacingOccurrences(of: "⏎", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        value = value.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: " *\\n *",
            with: "\n",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "[ \\t]+([,.;:!?%…])",
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "[ \\t]+([\\)\\]\\}])",
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "([\\(\\[\\{])[ \\t]+",
            with: "$1",
            options: .regularExpression
        )

        return value.trimmingCharacters(in: horizontalWhitespace)
    }

    /// Formats a live transcript for a multi-line panel: completed sentences
    /// start on a new line while SwiftUI remains free to wrap long sentences
    /// at word boundaries.
    public static func sentenceLines(_ text: String) -> String {
        normalize(text).replacingOccurrences(
            of: #"(?<=[.!?…])\s+"#,
            with: "\n",
            options: .regularExpression
        )
    }
}
