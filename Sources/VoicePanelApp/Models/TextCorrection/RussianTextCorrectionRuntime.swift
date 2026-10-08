import Foundation
import VoicePanelCore
import VoicePanelORTBridge

#if canImport(AppKit)
    import AppKit
#endif

enum RussianTextCorrectionRuntimeError: LocalizedError {
    case missingPackageFile(String)
    case loadFailed(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPackageFile(let filename): return "The Russian correction package is missing \(filename)."
        case .loadFailed(let message): return "The Russian correction model could not be loaded: \(message)"
        case .inferenceFailed(let message): return "Russian text correction failed: \(message)"
        }
    }
}

struct RussianTextCorrectionResult: Sendable {
    let text: String
    let proposedEditCount: Int
    let acceptedEditCount: Int
    let rejectedEditCount: Int
    let rejectedMeaningChangingEditCount: Int

    var didChange: Bool { acceptedEditCount > 0 }
}

final class RussianTextCorrectionRuntime: @unchecked Sendable {
    let model: RussianCorrectionModelID

    private let handle: OpaquePointer
    private let tokenizer: FREDT5Tokenizer
    private let inferenceLock = NSLock()

    private init(model: RussianCorrectionModelID, handle: OpaquePointer, tokenizer: FREDT5Tokenizer) {
        self.model = model
        self.handle = handle
        self.tokenizer = tokenizer
    }

    deinit {
        vp_ort_runtime_destroy(handle)
    }

    static func load(
        package: RussianCorrectionInstalledPackage,
        numberOfThreads: Int
    ) async throws -> RussianTextCorrectionRuntime {
        try await Task.detached(priority: .utility) {
            guard let encoderURL = package.url(for: .encoder) else {
                throw RussianTextCorrectionRuntimeError.missingPackageFile("encoder_model_quantized.onnx")
            }
            guard let decoderURL = package.url(for: .decoder) else {
                throw RussianTextCorrectionRuntimeError.missingPackageFile("decoder_model_quantized.onnx")
            }
            guard let vocabularyURL = package.url(for: .vocabulary) else {
                throw RussianTextCorrectionRuntimeError.missingPackageFile("vocab.json")
            }
            guard let mergesURL = package.url(for: .merges) else {
                throw RussianTextCorrectionRuntimeError.missingPackageFile("merges.txt")
            }

            let tokenizer = try FREDT5Tokenizer(vocabularyURL: vocabularyURL, mergesURL: mergesURL)
            var error = [CChar](repeating: 0, count: 2_048)
            let runtime = error.withUnsafeMutableBufferPointer { errorBuffer in
                encoderURL.path.withCString { encoderPath in
                    decoderURL.path.withCString { decoderPath in
                        vp_ort_runtime_create(
                            encoderPath,
                            decoderPath,
                            Int32(max(1, numberOfThreads)),
                            errorBuffer.baseAddress,
                            errorBuffer.count
                        )
                    }
                }
            }
            guard let runtime else {
                throw RussianTextCorrectionRuntimeError.loadFailed(Self.errorMessage(error))
            }
            return RussianTextCorrectionRuntime(model: package.model, handle: runtime, tokenizer: tokenizer)
        }.value
    }

    /// Runs SAGE as an edit proposal generator and accepts only local changes
    /// approved by the shared edit-based safety layer.
    func correct(_ text: String) async throws -> RussianTextCorrectionResult {
        let proposalDocument = try await Task.detached(priority: .userInitiated) { [self] in
            try inferenceLock.withRussianCorrectionRuntimeLock {
                try makeProposalDocumentSynchronously(text)
            }
        }.value

        var correctedParagraphs: [String] = []
        var allEdits: [TranscriptCandidateEdit] = []
        correctedParagraphs.reserveCapacity(proposalDocument.paragraphs.count)

        for paragraph in proposalDocument.paragraphs {
            var correctedPieces: [String] = []
            correctedPieces.reserveCapacity(paragraph.count)
            for proposal in paragraph {
                let allowedSpellingReplacements = await Self.validatedSpellingReplacements(
                    source: proposal.source,
                    candidate: proposal.candidate
                )
                let filtered = TranscriptCandidateEditFilter.apply(
                    source: proposal.source,
                    candidate: proposal.candidate,
                    configuration: .init(
                        allowedSpellingReplacements: allowedSpellingReplacements
                    )
                )
                correctedPieces.append(filtered.text)
                allEdits.append(contentsOf: filtered.edits)
            }
            correctedParagraphs.append(correctedPieces.filter { !$0.isEmpty }.joined(separator: " "))
        }

        let finalText = correctedParagraphs.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = allEdits.filter { $0.decision == .accepted }.count
        let rejected = allEdits.filter { $0.decision == .rejected }.count
        let rejectedMeaningChanging = allEdits.filter {
            $0.decision == .rejected
                && ($0.kind == .lexicalReplacement
                    || $0.kind == .insertion
                    || $0.kind == .deletion
                    || $0.kind == .structural)
        }.count

        return RussianTextCorrectionResult(
            text: finalText,
            proposedEditCount: allEdits.count,
            acceptedEditCount: accepted,
            rejectedEditCount: rejected,
            rejectedMeaningChangingEditCount: rejectedMeaningChanging
        )
    }

    private struct ProposalPiece: Sendable {
        let source: String
        let candidate: String
    }

    private struct ProposalDocument: Sendable {
        let paragraphs: [[ProposalPiece]]
    }

    private func makeProposalDocumentSynchronously(_ text: String) throws -> ProposalDocument {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ProposalDocument(paragraphs: []) }

        let paragraphs = normalized.components(separatedBy: "\n")
        let proposals = try paragraphs.map { paragraph -> [ProposalPiece] in
            let pieces = sentencePieces(from: paragraph)
            return try pieces.compactMap { piece in
                let clean = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return nil }
                guard shouldCorrect(clean) else {
                    return ProposalPiece(source: clean, candidate: clean)
                }
                let candidate = try proposeBoundedPiece(clean)
                return ProposalPiece(source: clean, candidate: candidate)
            }
        }
        return ProposalDocument(paragraphs: proposals)
    }

    private func proposeBoundedPiece(_ text: String) throws -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 90 {
            var outputs: [String] = []
            var index = 0
            while index < words.count {
                let end = min(words.count, index + 70)
                let sourceWindow = words[index..<end].joined(separator: " ")
                outputs.append(try proposeWindow(sourceWindow))
                index = end
            }
            return outputs.joined(separator: " ")
        }
        return try proposeWindow(text)
    }

    private func proposeWindow(_ source: String) throws -> String {
        let inputIDs = try tokenizer.encode(source)
        guard inputIDs.count <= 256 else { return source }
        let attentionMask = [Int64](repeating: 1, count: inputIDs.count)
        var error = [CChar](repeating: 0, count: 2_048)

        let hidden = error.withUnsafeMutableBufferPointer { errorBuffer in
            inputIDs.withUnsafeBufferPointer { ids in
                attentionMask.withUnsafeBufferPointer { mask in
                    vp_ort_encode(
                        handle,
                        ids.baseAddress,
                        mask.baseAddress,
                        ids.count,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        guard let hidden else {
            throw RussianTextCorrectionRuntimeError.inferenceFailed(Self.errorMessage(error))
        }
        defer { vp_ort_hidden_state_destroy(hidden) }

        var generated: [Int64] = [FREDT5Tokenizer.decoderStartTokenID]
        let maximumLength = min(256, max(inputIDs.count + 24, Int(Double(inputIDs.count) * 1.5)))
        while generated.count < maximumLength {
            var nextToken: Int64 = 0
            let succeeded = error.withUnsafeMutableBufferPointer { errorBuffer in
                attentionMask.withUnsafeBufferPointer { mask in
                    generated.withUnsafeBufferPointer { decoderIDs in
                        vp_ort_decode_next_token(
                            handle,
                            hidden,
                            mask.baseAddress,
                            mask.count,
                            decoderIDs.baseAddress,
                            decoderIDs.count,
                            &nextToken,
                            errorBuffer.baseAddress,
                            errorBuffer.count
                        )
                    }
                }
            }
            guard succeeded != 0 else {
                throw RussianTextCorrectionRuntimeError.inferenceFailed(Self.errorMessage(error))
            }
            if nextToken == FREDT5Tokenizer.endTokenID { break }
            generated.append(nextToken)
        }

        let candidate = tokenizer.decode(generated).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return source }
        let lengthRatio = Double(candidate.count) / Double(max(1, source.count))
        return (0.45...1.80).contains(lengthRatio) ? candidate : source
    }

    private func shouldCorrect(_ text: String) -> Bool {
        guard text.count >= 4 else { return false }
        var cyrillic = 0
        var latin = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
                if (0x0400...0x052F).contains(Int(scalar.value)) { cyrillic += 1 }
                if (0x0041...0x007A).contains(Int(scalar.value)) { latin += 1 }
            }
        }
        guard letters >= 4, cyrillic >= 3 else { return false }
        return Double(cyrillic) / Double(letters) >= 0.50 && latin < max(12, cyrillic)
    }

    @MainActor
    private static func validatedSpellingReplacements(
        source: String,
        candidate: String
    ) -> Set<TranscriptSpellingReplacement> {
        let pairs = TranscriptCandidateEditFilter.lexicalReplacementCandidates(
            source: source,
            candidate: candidate
        )
        guard !pairs.isEmpty else { return [] }

        #if canImport(AppKit)
            let checker = NSSpellChecker.shared
            guard
                let language = checker.availableLanguages.first(where: {
                    $0.lowercased().hasPrefix("ru")
                })
            else { return [] }

            return Set(
                pairs.filter { pair in
                    isMisspelled(pair.source, checker: checker, language: language)
                        && !isMisspelled(pair.replacement, checker: checker, language: language)
                })
        #else
            return []
        #endif
    }

    #if canImport(AppKit)
        @MainActor
        private static func isMisspelled(
            _ word: String,
            checker: NSSpellChecker,
            language: String
        ) -> Bool {
            var wordCount = 0
            let range = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: &wordCount
            )
            return range.location != NSNotFound && range.length > 0
        }
    #endif

    private func sentencePieces(from text: String) -> [String] {
        let pattern = "[^.!?…]+[.!?…]*"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func errorMessage(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress, baseAddress.pointee != 0 else {
                return "Unknown ONNX Runtime error."
            }
            return String(cString: baseAddress)
        }
    }
}

extension NSLock {
    fileprivate func withRussianCorrectionRuntimeLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
