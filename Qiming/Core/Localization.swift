import Foundation

enum Language: String, CaseIterable {
    case system, chinese, english
    var localeIdentifier: String {
        switch self {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }
}

@MainActor enum Localization {
    static var language: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "system") ?? .system
    }
    static var locale: Locale { Locale(identifier: language.localeIdentifier) }
    static func text(_ key: String) -> String {
        let bundle = Bundle.main.path(forResource: language.localeIdentifier, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func clock(_ seconds: TimeInterval, roundingUp: Bool = false) -> String {
        SessionTiming.clock(seconds, roundingUp: roundingUp)
    }
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

@MainActor func L(_ key: String) -> String { Localization.text(key) }
