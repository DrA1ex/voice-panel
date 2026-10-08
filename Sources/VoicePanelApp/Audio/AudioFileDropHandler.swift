import Foundation
import UniformTypeIdentifiers

@MainActor
enum AudioFileDropHandler {
    static func accept(
        providers: [NSItemProvider],
        onURL: @escaping @MainActor (URL) -> Void
    ) -> Bool {
        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else { return false }

        provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { item, _ in
            let url: URL?
            switch item {
            case let value as URL:
                url = value
            case let value as NSURL:
                url = value as URL
            case let data as Data:
                url = URL(dataRepresentation: data, relativeTo: nil)
            default:
                url = nil
            }
            guard let url else { return }
            Task { @MainActor in
                onURL(url)
            }
        }
        return true
    }
}
