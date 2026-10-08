import Foundation

/// Apple Speech closes an utterance after a long pause: it reports the phrase
/// once more with recognition metadata, then restarts `formattedString` from
/// empty inside the same task, without `isFinal`. The task's final result
/// likewise holds only its last utterance. Keep the closed phrases so a pause
/// never erases recognized text.
public struct SpeechUtteranceAccumulator: Equatable, Sendable {
    public private(set) var closedText = ""
    public private(set) var closedTokens: [TimedDraftToken] = []
    public private(set) var currentText = ""
    public private(set) var currentTokens: [TimedDraftToken] = []
    private var currentIsClosed = false

    public init() {}

    public var text: String {
        TranscriptTextMerger.join(closedText, currentText)
    }

    public var tokens: [TimedDraftToken] {
        closedTokens + currentTokens
    }

    /// Accepts Apple's latest hypothesis. Returns `true` when it starts a new
    /// utterance; the previous one is then retained as closed text.
    @discardableResult
    public mutating func observe(_ hypothesis: String, closesUtterance: Bool) -> Bool {
        let next = TranscriptTextNormalizer.normalize(hypothesis)
        // An empty result carries no evidence; keep the words already shown.
        guard !TranscriptTextMerger.isEffectivelyEmpty(next) else {
            currentIsClosed = currentIsClosed || closesUtterance
            return false
        }
        let restarts =
            currentIsClosed
            ? !Self.continues(currentText, with: next)
            : Self.restartsWithoutMetadata(currentText, with: next)
        if restarts { closeCurrent() }
        currentText = next
        currentIsClosed = closesUtterance
        return restarts
    }

    public mutating func replaceCurrentTokens(_ tokens: [TimedDraftToken]) {
        currentTokens = tokens
    }

    public mutating func reset() {
        self = Self()
    }

    private mutating func closeCurrent() {
        closedText = TranscriptTextMerger.join(closedText, currentText)
        closedTokens += currentTokens
        currentText = ""
        currentTokens = []
        currentIsClosed = false
    }

    /// Some OS versions keep the closed phrase as the start of the next
    /// hypothesis. Tolerate Apple's usual small revisions of that prefix.
    private static func continues(_ previous: String, with next: String) -> Bool {
        let old = keys(previous)
        let new = keys(next)
        guard !old.isEmpty else { return true }
        guard new.count >= old.count else { return false }
        return zip(old, new).filter { $0 == $1 }.count * 2 >= old.count
    }

    /// Fallback when metadata is missing: a much shorter hypothesis with an
    /// unrelated start is a new utterance, not a revision of the old one.
    private static func restartsWithoutMetadata(_ previous: String, with next: String) -> Bool {
        let old = keys(previous)
        let new = keys(next)
        guard old.count >= 4, new.count * 2 <= old.count else { return false }
        return !old.joined().hasPrefix(String(new.joined().prefix(4)))
    }

    static func keys(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
