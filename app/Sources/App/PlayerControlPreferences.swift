import Foundation

enum PlayerControlPreferences {
    static let visibilityKey = "player.showControlButtons"
    #if os(iOS) && !targetEnvironment(macCatalyst)
    static let defaultVisible = false
    #else
    static let defaultVisible = true
    #endif

    static func buttonsVisible(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: visibilityKey) != nil else { return defaultVisible }
        return defaults.bool(forKey: visibilityKey)
    }
}
