import Foundation

enum GigaAMArchitecture: String, Sendable {
    case ctc = "CTC"
    case rnnt = "RNN-T"
}

struct GigaAMModelFile: Hashable, Sendable {
    enum Role: String, Sendable {
        case model
        case encoder
        case decoder
        case joiner
        case tokens
    }

    let role: Role
    let filename: String
    let sha256: String

    var downloadWeight: Double {
        switch role {
        case .model, .encoder: return 0.96
        case .decoder, .joiner: return 0.015
        case .tokens: return 0.01
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx/resolve/main/\(filename)?download=true")!
    }
}

enum GigaAMModelID: String, CaseIterable, Identifiable, Sendable {
    case v3CTC = "v3_ctc"
    case v3RNNT = "v3_rnnt"
    case v3E2ECTC = "v3_e2e_ctc"
    case v3E2ERNNT = "v3_e2e_rnnt"

    var id: String { rawValue }

    var architecture: GigaAMArchitecture {
        switch self {
        case .v3CTC, .v3E2ECTC: return .ctc
        case .v3RNNT, .v3E2ERNNT: return .rnnt
        }
    }

    var hasPunctuationAndNormalization: Bool {
        switch self {
        case .v3E2ECTC, .v3E2ERNNT: return true
        case .v3CTC, .v3RNNT: return false
        }
    }

    var isPlainTextModel: Bool {
        !hasPunctuationAndNormalization
    }

    var relativeDraftSpeed: Int {
        switch self {
        case .v3CTC: return 4
        case .v3RNNT: return 3
        case .v3E2ECTC: return 2
        case .v3E2ERNNT: return 1
        }
    }

    static func draftChoices(for finalModel: GigaAMModelID) -> [GigaAMModelID] {
        allCases
            .filter { candidate in
                candidate != finalModel
                    && candidate.isPlainTextModel
                    && candidate.relativeDraftSpeed > finalModel.relativeDraftSpeed
            }
            .sorted { $0.relativeDraftSpeed > $1.relativeDraftSpeed }
    }

    var title: String {
        switch self {
        case .v3CTC: return "GigaAM v3 CTC"
        case .v3RNNT: return "GigaAM v3 RNN-T"
        case .v3E2ECTC: return "GigaAM v3 E2E CTC"
        case .v3E2ERNNT: return "GigaAM v3 E2E RNN-T"
        }
    }

    var capabilityLabel: String {
        hasPunctuationAndNormalization
            ? "Punctuation and text normalization"
            : "Plain text · no punctuation"
    }

    var detail: String {
        switch self {
        case .v3CTC:
            return "Fastest · plain Russian text · \(sizeLabel)"
        case .v3RNNT:
            return "More contextual · plain Russian text · \(sizeLabel)"
        case .v3E2ECTC:
            return "Faster final text with punctuation · \(sizeLabel)"
        case .v3E2ERNNT:
            return "Highest-quality final text with punctuation · \(sizeLabel)"
        }
    }

    var sizeLabel: String {
        switch self {
        case .v3CTC: return "about 319 MB"
        case .v3RNNT: return "about 324 MB"
        case .v3E2ECTC: return "about 320 MB"
        case .v3E2ERNNT: return "about 326 MB"
        }
    }

    var recommendedRole: String {
        switch self {
        case .v3CTC: return "Lowest-latency local draft option"
        case .v3RNNT: return "Accurate draft or direct recognition"
        case .v3E2ECTC: return "Balanced final refinement"
        case .v3E2ERNNT: return "Maximum-quality final refinement"
        }
    }

    var files: [GigaAMModelFile] {
        switch self {
        case .v3CTC:
            return [
                .init(
                    role: .model, filename: "gigaam_v3_ctc_int8.onnx",
                    sha256: "3905685b05941e79772e68acc8af5ac5aafb615fe57a38a719ad3291dbcbf3ed"),
                .init(
                    role: .tokens, filename: "gigaam_v3_ctc_tokens.txt",
                    sha256: "48c9111eb77c9c42d08ecc71c00c09407ef2cce01195d72b7cc0c3c08ce89213"),
            ]
        case .v3RNNT:
            return [
                .init(
                    role: .encoder, filename: "gigaam_v3_rnnt_encoder_int8.onnx",
                    sha256: "53138ee4241c22482a45f3f9f80b787749fa7456f29221c4652afb7a1f84b681"),
                .init(
                    role: .decoder, filename: "gigaam_v3_rnnt_decoder.onnx",
                    sha256: "633ef97f2c6c9ca11c91b6c7ee8f6054fc7a964e6b22d7a904fd096b458f0308"),
                .init(
                    role: .joiner, filename: "gigaam_v3_rnnt_joint.onnx",
                    sha256: "fd1d02f45c2ad3d6b67cc149811ad794ab4b020ed49a0a9e2790a8619d1cddd8"),
                .init(
                    role: .tokens, filename: "gigaam_v3_rnnt_tokens.txt",
                    sha256: "48c9111eb77c9c42d08ecc71c00c09407ef2cce01195d72b7cc0c3c08ce89213"),
            ]
        case .v3E2ECTC:
            return [
                .init(
                    role: .model, filename: "gigaam_v3_e2e_ctc_int8.onnx",
                    sha256: "0aacb41f70f0f5aaac4b45dd430337b9e16b180f22c72af04db8516e7609c3c0"),
                .init(
                    role: .tokens, filename: "gigaam_v3_e2e_ctc_tokens.txt",
                    sha256: "f8eb9b115e2748db9c40a5897cae11dd0678cc0b40fd7e25f8c43b3bf28715e4"),
            ]
        case .v3E2ERNNT:
            return [
                .init(
                    role: .encoder, filename: "gigaam_v3_e2e_rnnt_encoder_int8.onnx",
                    sha256: "2cac62d0c270bd128f898f2be1a2d34780d524a6e9483888ebac7b00f97410f1"),
                .init(
                    role: .decoder, filename: "gigaam_v3_e2e_rnnt_decoder.onnx",
                    sha256: "781971998e6a355d6a714f6932a30eab295e7ba0d14fd7e0f78c83b87e811860"),
                .init(
                    role: .joiner, filename: "gigaam_v3_e2e_rnnt_joint.onnx",
                    sha256: "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c"),
                .init(
                    role: .tokens, filename: "gigaam_v3_e2e_rnnt_tokens.txt",
                    sha256: "7ddf22514c42c531358182c81446a8159771e9921019f09ae743ea622d40221d"),
            ]
        }
    }
}

struct GigaAMInstalledPackage: Sendable {
    let model: GigaAMModelID
    let directory: URL

    func url(for role: GigaAMModelFile.Role) -> URL? {
        guard let file = model.files.first(where: { $0.role == role }) else { return nil }
        return directory.appendingPathComponent(file.filename)
    }
}
