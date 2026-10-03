import Foundation

/// Selects Russian for the guest's system UI and regional formatting.
enum IOSLanguageInstaller {
    static let globalPreferencesPath = "/private/var/mobile/Library/Preferences/.GlobalPreferences.plist"
    static let preferredLanguages = ["ru", "en"]
    static let locale = "ru_RU"

    static func apply(to builder: RootFilesystemBuilder) throws {
        guard builder.contains(globalPreferencesPath) else {
            throw HFSPlusError.missingPath(globalPreferencesPath)
        }
        try builder.editPropertyList(globalPreferencesPath) { preferences in
            preferences["AppleLanguages"] = preferredLanguages
            preferences["AppleLocale"] = locale
        }
    }
}
