import Foundation

enum AppLanguage: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var title: String {
        switch self {
        case .system: L("language.system")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

enum Localization {
    static var language: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system }
    static var identifier: String {
        if language != .system { return language.rawValue }
        return Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: Locale.preferredLanguages).first ?? "en"
    }
    static var locale: Locale { Locale(identifier: identifier) }
    static func string(_ key: String, language: String? = nil) -> String {
        let selected = language ?? identifier
        let path = Bundle.main.path(forResource: selected, ofType: "lproj") ?? Bundle.main.path(forResource: "en", ofType: "lproj")
        return path.flatMap(Bundle.init(path:))?.localizedString(forKey: key, value: nil, table: "Localizable") ?? key
    }
    static func format(_ key: String, _ arguments: [CVarArg], language: String? = nil) -> String {
        String(format: string(key, language: language), locale: Locale(identifier: language ?? identifier), arguments: arguments)
    }
    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }
    static func day(_ value: String) -> String {
        guard let date = date(value) else { return value }
        let f = DateFormatter(); f.locale = locale; f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateStyle = .medium
        return f.string(from: date)
    }
    static func dateRange(_ from: String, _ to: String) -> String {
        guard let start = date(from), let end = date(to) else { return "\(from) / \(to)" }
        let formatter = DateIntervalFormatter(); formatter.locale = locale; formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }
}
func L(_ key: String) -> String { Localization.string(key) }
func LF(_ key: String, _ arguments: CVarArg...) -> String { Localization.format(key, arguments) }
