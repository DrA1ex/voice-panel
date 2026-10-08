import Foundation

struct RussianCorrectionModelFile: Hashable, Sendable {
    enum Role: String, Sendable {
        case encoder
        case decoder
        case vocabulary
        case merges
    }

    let role: Role
    let filename: String
    let sha256: String?
    let minimumSize: Int64
    let downloadWeight: Double

    var downloadURL: URL {
        let repository: String
        let revision: String
        switch role {
        case .encoder, .decoder:
            repository = "krut42/voice-sage95m-int8"
            revision = "3343e7765f2cd668a04e3200f8753b382444f274"
        case .vocabulary, .merges:
            repository = "ai-forever/sage-fredt5-distilled-95m"
            revision = "ed51b4a46603931380951a3d8456685c9215864f"
        }
        return URL(
            string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)?download=true"
        )!
    }
}

enum RussianCorrectionModelID: String, CaseIterable, Identifiable, Sendable {
    case sageFREDT5Int8 = "sage-fredt5-95m-int8"

    var id: String { rawValue }
    var title: String { "SAGE FRED-T5 95M · INT8" }
    var detail: String { "Russian spelling, punctuation, and case correction · about 125 MB" }
    var sizeLabel: String { "about 125 MB" }

    var files: [RussianCorrectionModelFile] {
        [
            .init(
                role: .encoder,
                filename: "encoder_model_quantized.onnx",
                sha256: "c8fb179fb56ed9c80026891bf7339a5804072bc02351ddf76d792293b70c2821",
                minimumSize: 44_000_000,
                downloadWeight: 0.36
            ),
            .init(
                role: .decoder,
                filename: "decoder_model_quantized.onnx",
                sha256: "062cfd09b268fb9e12dd45ad57bf1a5969956b19094e448321c9e2b431b0e7b2",
                minimumSize: 76_000_000,
                downloadWeight: 0.62
            ),
            .init(
                role: .vocabulary,
                filename: "vocab.json",
                sha256: nil,
                minimumSize: 1_000_000,
                downloadWeight: 0.015
            ),
            .init(
                role: .merges,
                filename: "merges.txt",
                sha256: nil,
                minimumSize: 1_000_000,
                downloadWeight: 0.005
            ),
        ]
    }
}

struct RussianCorrectionInstalledPackage: Sendable {
    let model: RussianCorrectionModelID
    let directory: URL

    func url(for role: RussianCorrectionModelFile.Role) -> URL? {
        guard let file = model.files.first(where: { $0.role == role }) else { return nil }
        return directory.appendingPathComponent(file.filename)
    }
}
