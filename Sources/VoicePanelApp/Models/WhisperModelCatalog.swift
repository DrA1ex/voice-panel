import Foundation

enum WhisperChecksum: Equatable, Sendable {
    case sha1(String)
    case sha256(String)

    var value: String {
        switch self {
        case .sha1(let value), .sha256(let value): return value
        }
    }

    var label: String {
        switch self {
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        }
    }
}

enum WhisperCoreMLEncoderID: String, CaseIterable, Identifiable, Sendable {
    case tiny
    case tinyEnglish = "tiny.en"
    case base
    case baseEnglish = "base.en"
    case small
    case smallEnglish = "small.en"
    case medium
    case mediumEnglish = "medium.en"
    case largeV1 = "large-v1"
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "Whisper Tiny Core ML encoder"
        case .tinyEnglish: return "Whisper Tiny English Core ML encoder"
        case .base: return "Whisper Base Core ML encoder"
        case .baseEnglish: return "Whisper Base English Core ML encoder"
        case .small: return "Whisper Small Core ML encoder"
        case .smallEnglish: return "Whisper Small English Core ML encoder"
        case .medium: return "Whisper Medium Core ML encoder"
        case .mediumEnglish: return "Whisper Medium English Core ML encoder"
        case .largeV1: return "Whisper Large v1 Core ML encoder"
        case .largeV2: return "Whisper Large v2 Core ML encoder"
        case .largeV3: return "Whisper Large v3 Core ML encoder"
        case .largeV3Turbo: return "Whisper Large v3 Turbo Core ML encoder"
        }
    }

    var archiveFilename: String { "ggml-\(rawValue)-encoder.mlmodelc.zip" }
    var directoryFilename: String { "ggml-\(rawValue)-encoder.mlmodelc" }

    var downloadURL: URL {
        URL(
            string:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(archiveFilename)"
        )!
    }

    var expectedSHA256: String {
        switch self {
        case .tiny: return "c88cbd2648e1f5415092bcf5256add463a0f19943e6938f46e8d4ffdebd47739"
        case .tinyEnglish: return "82b32eef73c94bb0c432a776a047b757d9525c26d84038a15d8798d7c8d1ee58"
        case .base: return "7e6ab77041942572f239b5b602f8aaa1c3ed29d73e3d8f20abea03a773541089"
        case .baseEnglish: return "8cf860309e2449e2bdc8be834cf838ab2565747ecc8c0ef914ef5975115e192b"
        case .small: return "de43fb9fed471e95c19e60ae67575c2bf09e8fb607016da171b06ddad313988b"
        case .smallEnglish: return "b2ef1c506378b825b4b4341979a93e1656b5d6c129f17114cfb8fb78aabc2f89"
        case .medium: return "79b0b8d436d47d3f24dd3afc91f19447dd686a4f37521b2f6d9c30a642133fbd"
        case .mediumEnglish: return "cdc44fee3c62b5743913e3147ed75f4e8ecfb52dd7a0f0f7387094b406ff0ee6"
        case .largeV1: return "d10d24a4272572fee07843ffc2e4e4ceebd1d0b0831a142dd2fdb3d56d5bf56e"
        case .largeV2: return "c65d28737f51d09dff3b9da9d26c2ab6f5d82857c9b049ce383d64c2502a5541"
        case .largeV3: return "47837be7594a29429ec08620043390c4d6d467f8bd362df09e9390ace76a55a4"
        case .largeV3Turbo: return "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a"
        }
    }

    var archiveByteCount: Int64 {
        switch self {
        case .tiny: return 15_037_446
        case .tinyEnglish: return 15_034_655
        case .base: return 37_922_638
        case .baseEnglish: return 37_950_917
        case .small: return 163_083_239
        case .smallEnglish: return 162_952_446
        case .medium: return 567_829_413
        case .mediumEnglish: return 566_993_085
        case .largeV1: return 1_177_529_527
        case .largeV2: return 1_174_643_458
        case .largeV3: return 1_175_711_232
        case .largeV3Turbo: return 1_173_393_014
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: archiveByteCount, countStyle: .file)
    }
}

enum WhisperModelID: String, CaseIterable, Identifiable, Sendable {
    case tiny
    case tinyEnglish = "tiny.en"
    case base
    case baseEnglish = "base.en"
    case small
    case smallEnglish = "small.en"
    case smallEnglishDiarization = "small.en-tdrz"
    case medium
    case mediumQ5 = "medium-q5_0"
    case mediumQ8 = "medium-q8_0"
    case mediumEnglish = "medium.en"
    case mediumEnglishQ5 = "medium.en-q5_0"
    case mediumEnglishQ8 = "medium.en-q8_0"
    case largeV1 = "large-v1"
    case largeV2 = "large-v2"
    case largeV2Q5 = "large-v2-q5_0"
    case largeV3 = "large-v3"
    case largeV3Q5 = "large-v3-q5_0"
    case largeV3Turbo = "large-v3-turbo"
    case largeV3TurboQ5 = "large-v3-turbo-q5_0"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "Whisper Tiny"
        case .tinyEnglish: return "Whisper Tiny · English"
        case .base: return "Whisper Base"
        case .baseEnglish: return "Whisper Base · English"
        case .small: return "Whisper Small"
        case .smallEnglish: return "Whisper Small · English"
        case .smallEnglishDiarization: return "Whisper Small · English · Speaker turns"
        case .medium: return "Whisper Medium"
        case .mediumQ5: return "Whisper Medium · Q5"
        case .mediumQ8: return "Whisper Medium · Q8"
        case .mediumEnglish: return "Whisper Medium · English"
        case .mediumEnglishQ5: return "Whisper Medium · English · Q5"
        case .mediumEnglishQ8: return "Whisper Medium · English · Q8"
        case .largeV1: return "Whisper Large v1"
        case .largeV2: return "Whisper Large v2"
        case .largeV2Q5: return "Whisper Large v2 · Q5"
        case .largeV3: return "Whisper Large v3"
        case .largeV3Q5: return "Whisper Large v3 · Q5"
        case .largeV3Turbo: return "Whisper Large v3 Turbo"
        case .largeV3TurboQ5: return "Whisper Large v3 Turbo · Q5"
        }
    }

    var detail: String {
        var components = [capabilityLabel, sizeLabel]
        if isQuantized {
            components.insert(quantizationLabel, at: 1)
        }
        if supportsDiarization {
            components.insert("Speaker-turn markers", at: 1)
        }
        return components.joined(separator: " · ")
    }

    var capabilityLabel: String { isEnglishOnly ? "English only" : "Multilingual" }

    var isEnglishOnly: Bool {
        switch self {
        case .tinyEnglish, .baseEnglish, .smallEnglish, .smallEnglishDiarization,
            .mediumEnglish, .mediumEnglishQ5, .mediumEnglishQ8:
            return true
        default:
            return false
        }
    }

    var quantizationLabel: String {
        switch self {
        case .mediumQ5, .mediumEnglishQ5, .largeV2Q5, .largeV3Q5, .largeV3TurboQ5:
            return "Q5 quantized"
        case .mediumQ8, .mediumEnglishQ8:
            return "Q8 quantized"
        default:
            return "FP16"
        }
    }

    var isQuantized: Bool {
        switch self {
        case .mediumQ5, .mediumQ8, .mediumEnglishQ5, .mediumEnglishQ8,
            .largeV2Q5, .largeV3Q5, .largeV3TurboQ5:
            return true
        default:
            return false
        }
    }

    var supportsDiarization: Bool { self == .smallEnglishDiarization }

    var coreMLEncoder: WhisperCoreMLEncoderID? {
        switch self {
        case .tiny: return .tiny
        case .tinyEnglish: return .tinyEnglish
        case .base: return .base
        case .baseEnglish: return .baseEnglish
        case .small: return .small
        case .smallEnglish: return .smallEnglish
        case .smallEnglishDiarization: return nil
        case .medium, .mediumQ5, .mediumQ8: return .medium
        case .mediumEnglish, .mediumEnglishQ5, .mediumEnglishQ8: return .mediumEnglish
        case .largeV1: return .largeV1
        case .largeV2, .largeV2Q5: return .largeV2
        case .largeV3, .largeV3Q5: return .largeV3
        case .largeV3Turbo, .largeV3TurboQ5: return .largeV3Turbo
        }
    }

    /// Approximate upstream relative speed. Larger values are faster.
    /// It is used only to filter sensible local draft choices, never to
    /// silently replace a model selected by the user.
    var relativeSpeed: Double {
        switch self {
        case .tiny, .tinyEnglish:
            return 10
        case .base, .baseEnglish:
            return 7
        case .small, .smallEnglish, .smallEnglishDiarization:
            return 4
        case .medium, .mediumEnglish:
            return 2
        case .mediumQ5, .mediumEnglishQ5:
            return 2.5
        case .mediumQ8, .mediumEnglishQ8:
            return 2.2
        case .largeV1, .largeV2, .largeV3:
            return 1
        case .largeV2Q5, .largeV3Q5:
            return 1.4
        case .largeV3Turbo:
            return 8
        case .largeV3TurboQ5:
            return 9
        }
    }

    var sizeMiB: Int {
        switch self {
        case .tiny, .tinyEnglish:
            return 75
        case .base, .baseEnglish:
            return 142
        case .small, .smallEnglish:
            return 466
        case .smallEnglishDiarization:
            return 465
        case .medium, .mediumEnglish, .largeV3Turbo:
            return 1_536
        case .mediumQ5, .mediumEnglishQ5:
            return 514
        case .mediumQ8, .mediumEnglishQ8:
            return 786
        case .largeV1, .largeV2, .largeV3:
            return 2_970
        case .largeV2Q5, .largeV3Q5:
            return 1_126
        case .largeV3TurboQ5:
            return 547
        }
    }

    var minimumExpectedByteCount: Int64 {
        Int64(Double(sizeMiB) * 1_024 * 1_024 * 0.70)
    }

    var sizeLabel: String {
        sizeMiB >= 1_024
            ? String(format: "about %.1f GB", Double(sizeMiB) / 1_024)
            : "about \(sizeMiB) MB"
    }

    var filename: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    /// Checksums are pinned to the official whisper.cpp model repository.
    var expectedChecksum: WhisperChecksum {
        switch self {
        case .tiny: return .sha1("bd577a113a864445d4c299885e0cb97d4ba92b5f")
        case .tinyEnglish: return .sha1("c78c86eb1a8faa21b369bcd33207cc90d64ae9df")
        case .base: return .sha1("465707469ff3a37a2b9b8d8f89f2f99de7299dac")
        case .baseEnglish: return .sha1("137c40403d78fd54d454da0f9bd998f78703390c")
        case .small: return .sha1("55356645c2b361a969dfd0ef2c5a50d530afd8d5")
        case .smallEnglish: return .sha1("db8a495a91d927739e50b3fc1cc4c6b8f6c2d022")
        case .smallEnglishDiarization: return .sha1("b6c6e7e89af1a35c08e6de56b66ca6a02a2fdfa1")
        case .medium: return .sha1("fd9727b6e1217c2f614f9b698455c4ffd82463b4")
        case .mediumQ5:
            return .sha256("19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f")
        case .mediumQ8:
            return .sha256("42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502")
        case .mediumEnglish: return .sha1("8c30f0e44ce9560643ebd10bbe50cd20eafd3723")
        case .mediumEnglishQ5:
            return .sha256("76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0")
        case .mediumEnglishQ8:
            return .sha256("43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c")
        case .largeV1: return .sha1("b1caaf735c4cc1429223d5a74f0f4d0b9b59a299")
        case .largeV2: return .sha1("0f4c8e34f21cf1a914c59d8b3ce882345ad349d6")
        case .largeV2Q5: return .sha1("00e39f2196344e901b3a2bd5814807a769bd1630")
        case .largeV3: return .sha1("ad82bf6a9043ceed055076d0fd39f5f186ff8062")
        case .largeV3Q5: return .sha1("e6e2ed78495d403bef4b7cff42ef4aaadcfea8de")
        case .largeV3Turbo: return .sha1("4af2b29d7ec73d781377bfd1758ca957a807e941")
        case .largeV3TurboQ5: return .sha1("e050f7970618a659205450ad97eb95a18d69c9ee")
        }
    }

    func supports(languageCode: String) -> Bool {
        !isEnglishOnly || languageCode == "en"
    }

    static func draftChoices(
        for finalModel: WhisperModelID,
        languageCode: String
    ) -> [WhisperModelID] {
        allCases
            .filter { candidate in
                candidate != finalModel
                    && !candidate.supportsDiarization
                    && candidate.supports(languageCode: languageCode)
                    && candidate.relativeSpeed > finalModel.relativeSpeed
                    && candidate.sizeMiB < finalModel.sizeMiB
            }
            .sorted {
                if $0.relativeSpeed == $1.relativeSpeed {
                    return $0.sizeMiB < $1.sizeMiB
                }
                return $0.relativeSpeed > $1.relativeSpeed
            }
    }
}
