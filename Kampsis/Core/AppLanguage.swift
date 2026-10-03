import Foundation

/// языки интерфейса: выбор хранится в стандартной настройке macOS для приложения
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"

    var id: Self { self }

    var title: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }
}

/// при первом запуске язык приложения английский независимо от языка macOS
func prepareAppLanguage(in store: UserDefaults, domain: String) {
    guard store.persistentDomain(forName: domain)?["AppleLanguages"] == nil else { return }
    store.set([AppLanguage.english.rawValue], forKey: "AppleLanguages")
}
