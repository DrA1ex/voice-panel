import Foundation

enum LocalONNXModelFamily: String, Sendable {
    case qwen3ASR
    case parakeet
}

struct LocalONNXModelFile: Hashable, Sendable {
    enum Role: String, Sendable {
        case convFrontend
        case encoder
        case decoder
        case joiner
        case tokens
        case tokenizerConfig
        case tokenizerVocabulary
        case tokenizerMerges
    }

    enum Integrity: Hashable, Sendable {
        case pinnedSHA256(String)
        case huggingFaceContentAddressed
    }

    let role: Role
    let relativePath: String
    let integrity: Integrity
    let minimumSize: Int64
    let downloadWeight: Double
    let downloadURL: URL
}

enum LocalONNXModelID: String, CaseIterable, Identifiable, Sendable {
    case qwen3ASR06BInt8 = "qwen3_asr_0_6b_int8"
    case qwen3ASR17BInt8 = "qwen3_asr_1_7b_int8"
    case parakeetTDT06BV3Int8 = "parakeet_tdt_0_6b_v3_int8"

    var id: String { rawValue }

    static var qwen3ASRChoices: [LocalONNXModelID] {
        allCases.filter { $0.family == .qwen3ASR }
    }

    var family: LocalONNXModelFamily {
        switch self {
        case .qwen3ASR06BInt8, .qwen3ASR17BInt8: return .qwen3ASR
        case .parakeetTDT06BV3Int8: return .parakeet
        }
    }

    var title: String {
        switch self {
        case .qwen3ASR06BInt8: return "Qwen3-ASR 0.6B · INT8"
        case .qwen3ASR17BInt8: return "Qwen3-ASR 1.7B · INT8"
        case .parakeetTDT06BV3Int8: return "Parakeet TDT 0.6B v3 · INT8"
        }
    }

    var shortTitle: String {
        switch self {
        case .qwen3ASR06BInt8: return "Qwen3-ASR 0.6B"
        case .qwen3ASR17BInt8: return "Qwen3-ASR 1.7B"
        case .parakeetTDT06BV3Int8: return "Parakeet TDT"
        }
    }

    var capabilityLabel: String {
        switch self {
        case .qwen3ASR06BInt8:
            return "Multilingual · punctuation · automatic language detection"
        case .qwen3ASR17BInt8:
            return "Larger multilingual model · punctuation · automatic language detection"
        case .parakeetTDT06BV3Int8:
            return "25 European languages · punctuation · fast transducer decoding"
        }
    }

    var detail: String {
        switch self {
        case .qwen3ASR06BInt8:
            return "Balanced Qwen model · \(sizeLabel)"
        case .qwen3ASR17BInt8:
            return "Larger community sherpa-onnx export · \(sizeLabel)"
        case .parakeetTDT06BV3Int8:
            return "Lower-latency multilingual final text · \(sizeLabel)"
        }
    }

    var sizeLabel: String {
        switch self {
        case .qwen3ASR06BInt8: return "about 1 GB"
        case .qwen3ASR17BInt8: return "about 2.3 GB"
        case .parakeetTDT06BV3Int8: return "about 640 MB"
        }
    }

    var recommendedRole: String {
        switch self {
        case .qwen3ASR06BInt8:
            return "Recommended default when quality and finalization latency both matter."
        case .qwen3ASR17BInt8:
            return "Try for higher recognition quality on a Mac with enough memory; this export is experimental."
        case .parakeetTDT06BV3Int8:
            return "Use for faster local processing on Russian and other European speech."
        }
    }

    var isExperimental: Bool {
        self == .qwen3ASR17BInt8
    }

    var files: [LocalONNXModelFile] {
        switch self {
        case .qwen3ASR06BInt8:
            let base = "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main"
            return [
                pinnedFile(
                    role: .convFrontend,
                    path: "conv_frontend.onnx",
                    sha256: "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e",
                    minimumSize: 40_000_000,
                    weight: 0.045,
                    base: base
                ),
                pinnedFile(
                    role: .encoder,
                    path: "encoder.int8.onnx",
                    sha256: "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9",
                    minimumSize: 170_000_000,
                    weight: 0.185,
                    base: base
                ),
                pinnedFile(
                    role: .decoder,
                    path: "decoder.int8.onnx",
                    sha256: "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771",
                    minimumSize: 700_000_000,
                    weight: 0.765,
                    base: base
                ),
                pinnedFile(
                    role: .tokenizerConfig,
                    path: "tokenizer/tokenizer_config.json",
                    sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c",
                    minimumSize: 1_000,
                    weight: 0.001,
                    base: base
                ),
                pinnedFile(
                    role: .tokenizerVocabulary,
                    path: "tokenizer/vocab.json",
                    sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                    minimumSize: 2_000_000,
                    weight: 0.002,
                    base: base
                ),
                pinnedFile(
                    role: .tokenizerMerges,
                    path: "tokenizer/merges.txt",
                    sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
                    minimumSize: 1_000_000,
                    weight: 0.002,
                    base: base
                ),
            ]

        case .qwen3ASR17BInt8:
            let base = "https://huggingface.co/thieunv/sherpa-onnx-qwen3-asr-1.7B-int8/resolve/main"
            return [
                huggingFaceContentAddressedFile(
                    role: .convFrontend,
                    path: "conv_frontend.onnx",
                    minimumSize: 40_000_000,
                    weight: 0.018,
                    base: base
                ),
                huggingFaceContentAddressedFile(
                    role: .encoder,
                    path: "encoder.int8.onnx",
                    minimumSize: 170_000_000,
                    weight: 0.075,
                    base: base
                ),
                huggingFaceContentAddressedFile(
                    role: .decoder,
                    path: "decoder.int8.onnx",
                    minimumSize: 1_500_000_000,
                    weight: 0.902,
                    base: base
                ),
                huggingFaceContentAddressedFile(
                    role: .tokenizerConfig,
                    path: "tokenizer/tokenizer_config.json",
                    minimumSize: 1_000,
                    weight: 0.001,
                    base: base
                ),
                huggingFaceContentAddressedFile(
                    role: .tokenizerVocabulary,
                    path: "tokenizer/vocab.json",
                    minimumSize: 2_000_000,
                    weight: 0.002,
                    base: base
                ),
                huggingFaceContentAddressedFile(
                    role: .tokenizerMerges,
                    path: "tokenizer/merges.txt",
                    minimumSize: 1_000_000,
                    weight: 0.002,
                    base: base
                ),
            ]

        case .parakeetTDT06BV3Int8:
            let base = "https://huggingface.co/csukuangfj2/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main"
            return [
                pinnedFile(
                    role: .encoder,
                    path: "encoder.int8.onnx",
                    sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247",
                    minimumSize: 600_000_000,
                    weight: 0.965,
                    base: base
                ),
                pinnedFile(
                    role: .decoder,
                    path: "decoder.int8.onnx",
                    sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e",
                    minimumSize: 10_000_000,
                    weight: 0.02,
                    base: base
                ),
                pinnedFile(
                    role: .joiner,
                    path: "joiner.int8.onnx",
                    sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3",
                    minimumSize: 5_000_000,
                    weight: 0.01,
                    base: base
                ),
                pinnedFile(
                    role: .tokens,
                    path: "tokens.txt",
                    sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
                    minimumSize: 80_000,
                    weight: 0.005,
                    base: base
                ),
            ]
        }
    }

    private func pinnedFile(
        role: LocalONNXModelFile.Role,
        path: String,
        sha256: String,
        minimumSize: Int64,
        weight: Double,
        base: String
    ) -> LocalONNXModelFile {
        file(
            role: role,
            path: path,
            integrity: .pinnedSHA256(sha256),
            minimumSize: minimumSize,
            weight: weight,
            base: base
        )
    }

    private func huggingFaceContentAddressedFile(
        role: LocalONNXModelFile.Role,
        path: String,
        minimumSize: Int64,
        weight: Double,
        base: String
    ) -> LocalONNXModelFile {
        file(
            role: role,
            path: path,
            integrity: .huggingFaceContentAddressed,
            minimumSize: minimumSize,
            weight: weight,
            base: base
        )
    }

    private func file(
        role: LocalONNXModelFile.Role,
        path: String,
        integrity: LocalONNXModelFile.Integrity,
        minimumSize: Int64,
        weight: Double,
        base: String
    ) -> LocalONNXModelFile {
        LocalONNXModelFile(
            role: role,
            relativePath: path,
            integrity: integrity,
            minimumSize: minimumSize,
            downloadWeight: weight,
            downloadURL: URL(string: "\(base)/\(path)?download=true")!
        )
    }
}

struct LocalONNXInstalledPackage: Sendable {
    let model: LocalONNXModelID
    let directory: URL

    func url(for role: LocalONNXModelFile.Role) -> URL? {
        guard let file = model.files.first(where: { $0.role == role }) else { return nil }
        return directory.appendingPathComponent(file.relativePath)
    }

    var tokenizerDirectory: URL {
        directory.appendingPathComponent("tokenizer", isDirectory: true)
    }
}
