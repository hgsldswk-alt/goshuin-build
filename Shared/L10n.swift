import Foundation

final class LocalizationBundle: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: LocalizationBundle.self), comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }

    static func regionName(_ id: Int, language: String) -> String {
        let bundle = Bundle(for: LocalizationBundle.self)
        guard let folder = bundle.path(forResource: language, ofType: "lproj"), let languageBundle = Bundle(path: folder)
        else { return t("region.\(id)") }
        return NSLocalizedString("region.\(id)", bundle: languageBundle, comment: "")
    }
}
