import Foundation

enum FREDT5TokenizerError: LocalizedError {
    case invalidVocabulary
    case invalidMerges
    case unknownToken(String)

    var errorDescription: String? {
        switch self {
        case .invalidVocabulary: return "The SAGE vocabulary is invalid."
        case .invalidMerges: return "The SAGE BPE merge table is invalid."
        case .unknownToken(let token): return "The SAGE tokenizer cannot encode token \(token)."
        }
    }
}

final class FREDT5Tokenizer: @unchecked Sendable {
    static let encoderStartTokenID: Int64 = 50_357
    static let decoderStartTokenID: Int64 = 0
    static let endTokenID: Int64 = 2

    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    private let vocabulary: [String: Int64]
    private let inverseVocabulary: [Int64: String]
    private let mergeRanks: [Pair: Int]
    private let byteEncoder: [UInt8: UnicodeScalar]
    private let byteDecoder: [UnicodeScalar: UInt8]
    private let expression: NSRegularExpression
    private let cacheLock = NSLock()
    private var bpeCache: [String: [String]] = [:]

    init(vocabularyURL: URL, mergesURL: URL) throws {
        let vocabularyData = try Data(contentsOf: vocabularyURL)
        guard let decoded = try JSONSerialization.jsonObject(with: vocabularyData) as? [String: NSNumber],
            decoded.count > 40_000
        else { throw FREDT5TokenizerError.invalidVocabulary }
        vocabulary = decoded.mapValues(\.int64Value)
        inverseVocabulary = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })

        let mergeText = try String(contentsOf: mergesURL, encoding: .utf8)
        let mergeLines = mergeText.split(whereSeparator: { $0.isNewline })
        var ranks: [Pair: Int] = [:]
        for line in mergeLines where !line.hasPrefix("#") {
            let components = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            ranks[Pair(left: components[0], right: components[1])] = ranks.count
        }
        guard ranks.count > 10_000 else { throw FREDT5TokenizerError.invalidMerges }
        mergeRanks = ranks

        let maps = Self.makeByteMaps()
        byteEncoder = maps.encoder
        byteDecoder = maps.decoder
        expression = try NSRegularExpression(
            pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+",
            options: []
        )
    }

    func encode(_ text: String) throws -> [Int64] {
        var ids: [Int64] = [Self.encoderStartTokenID]
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, options: [], range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let piece = String(text[range])
            let encodedPiece = piece.utf8.map { byteEncoder[$0]! }.map(String.init).joined()
            for token in bpe(encodedPiece) {
                guard let id = vocabulary[token] else { throw FREDT5TokenizerError.unknownToken(token) }
                ids.append(id)
            }
        }
        ids.append(Self.endTokenID)
        return ids
    }

    func decode(_ ids: [Int64]) -> String {
        let encoded = ids.compactMap { id -> String? in
            guard id != Self.decoderStartTokenID,
                id != Self.endTokenID,
                id != Self.encoderStartTokenID
            else { return nil }
            return inverseVocabulary[id]
        }.joined()

        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.utf8.count)
        for scalar in encoded.unicodeScalars {
            if let byte = byteDecoder[scalar] { bytes.append(byte) }
        }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    private func bpe(_ token: String) -> [String] {
        if let cached = cacheLock.withFREDTokenizerLock({ bpeCache[token] }) { return cached }
        var symbols = token.map(String.init)
        guard symbols.count > 1 else { return symbols }

        while true {
            var bestIndex: Int?
            var bestRank = Int.max
            guard symbols.count > 1 else { break }
            for index in 0..<(symbols.count - 1) {
                let rank = mergeRanks[Pair(left: symbols[index], right: symbols[index + 1])] ?? Int.max
                if rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard let index = bestIndex, bestRank != Int.max else { break }
            symbols[index] += symbols[index + 1]
            symbols.remove(at: index + 1)
        }

        cacheLock.withFREDTokenizerLock { bpeCache[token] = symbols }
        return symbols
    }

    private static func makeByteMaps() -> (
        encoder: [UInt8: UnicodeScalar],
        decoder: [UnicodeScalar: UInt8]
    ) {
        var byteValues = Array(33...126) + Array(161...172) + Array(174...255)
        var scalarValues = byteValues
        var additionalScalar = 0
        for value in 0...255 where !byteValues.contains(value) {
            byteValues.append(value)
            scalarValues.append(256 + additionalScalar)
            additionalScalar += 1
        }

        var encoder: [UInt8: UnicodeScalar] = [:]
        var decoder: [UnicodeScalar: UInt8] = [:]
        for (byte, scalar) in zip(byteValues, scalarValues) {
            guard let byte = UInt8(exactly: byte), let unicode = UnicodeScalar(scalar) else { continue }
            encoder[byte] = unicode
            decoder[unicode] = byte
        }
        return (encoder, decoder)
    }
}

extension NSLock {
    fileprivate func withFREDTokenizerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
