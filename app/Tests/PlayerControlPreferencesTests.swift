import XCTest
@testable import Clannad

final class PlayerControlPreferencesTests: XCTestCase {
    func testFreshTouchDeviceDefaultsToHiddenButtons() {
        withDefaults { defaults in
            XCTAssertFalse(PlayerControlPreferences.buttonsVisible(in: defaults))
        }
    }

    func testSavedChoiceCanEnableAndDisableButtons() {
        withDefaults { defaults in
            defaults.set(true, forKey: PlayerControlPreferences.visibilityKey)
            XCTAssertTrue(PlayerControlPreferences.buttonsVisible(in: defaults))
            defaults.set(false, forKey: PlayerControlPreferences.visibilityKey)
            XCTAssertFalse(PlayerControlPreferences.buttonsVisible(in: defaults))
        }
    }

    private func withDefaults(_ action: (UserDefaults) -> Void) {
        let name = "ClannadControlsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        action(defaults)
    }
}
