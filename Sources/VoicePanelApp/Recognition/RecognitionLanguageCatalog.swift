import Foundation
import Speech
import whisper

struct RecognitionLanguageOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
}

enum RecognitionLanguageCatalog {
    static func appleSpeechOptions(locale: Locale = .current) -> [RecognitionLanguageOption] {
        SFSpeechRecognizer.supportedLocales()
            .map { supportedLocale in
                let identifier = supportedLocale.identifier
                let title =
                    locale.localizedString(forIdentifier: identifier)
                    ?? supportedLocale.localizedString(forIdentifier: identifier)
                    ?? identifier
                return RecognitionLanguageOption(
                    id: identifier,
                    title: title.capitalized(with: locale),
                    subtitle: identifier
                )
            }
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    static func whisperOptions() -> [RecognitionLanguageOption] {
        var options = [
            RecognitionLanguageOption(
                id: "auto",
                title: "Auto Detect",
                subtitle: "Whisper chooses the spoken language"
            )
        ]

        let maximumID = whisper_lang_max_id()
        guard maximumID >= 0 else { return options }

        for languageID in 0...maximumID {
            guard let shortPointer = whisper_lang_str(languageID),
                let fullPointer = whisper_lang_str_full(languageID)
            else {
                continue
            }
            let code = String(cString: shortPointer)
            let name = String(cString: fullPointer)
            options.append(
                RecognitionLanguageOption(
                    id: code,
                    title: name.capitalized,
                    subtitle: code
                ))
        }

        let auto = options.removeFirst()
        options.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        options.insert(auto, at: 0)
        return options
    }
}
