import Foundation

/// Centralized `@AppStorage` key names so screens that share a setting
/// (e.g. Settings and Firmware) can't drift apart via a typo.
enum AppStorageKeys {
    static let appearance = "podium.appearance"
    static let iPodCase = "podium.iPodCase"
    static let experimentalAudio = "podium.experimentalAudio"
    static let experimentalFirmware = "podium.experimentalFirmware"
    static let experimentalDisplayResolution = "podium.experimentalDisplayResolution"
    static let customDisplayWidth = "podium.customDisplayWidth"
    static let customDisplayHeight = "podium.customDisplayHeight"
    static let confirmBeforeDeletingFirmware = "podium.confirmBeforeDeletingFirmware"
    static let showDeveloperSettings = "podium.showDeveloperSettings"
    static let showFrameRate = "podium.showFrameRate"
    static let skipInitialSetup = "podium.skipInitialSetup"
}
