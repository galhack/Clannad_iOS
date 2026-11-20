import XCTest
import UIKit
@testable import Clannad

@MainActor
final class PlayerMenuTests: XCTestCase {
    func testGameMenuProvidesBothActionsAndShortcuts() throws {
        let menu = AppDelegate.playerMenu()
        XCTAssertEqual(menu.title, "游戏")
        let commands = try XCTUnwrap(menu.children as? [UIKeyCommand])
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].action, #selector(SiglusPlayerViewController.showGameMenuCommand(_:)))
        XCTAssertEqual(commands[1].action, #selector(SiglusPlayerViewController.toggleGameSkipCommand(_:)))
        XCTAssertEqual(commands.map(\.input), ["m", "f"])
        XCTAssertTrue(commands.allSatisfy { $0.modifierFlags == [.command, .shift] })
    }

    func testCommandsAreDisabledBeforeEngineStarts() {
        let player = SiglusPlayerViewController(gameRoot: URL(fileURLWithPath: "/unused"),
                                               title: "Test", onExit: {})
        for command in AppDelegate.playerMenu().children.compactMap({ $0 as? UICommand }) {
            XCTAssertFalse(player.canPerformAction(command.action, withSender: command))
        }
    }

    func testFastForwardCommandStartsUnchecked() throws {
        let player = SiglusPlayerViewController(gameRoot: URL(fileURLWithPath: "/unused"),
                                               title: "Test", onExit: {})
        let command = try XCTUnwrap(AppDelegate.playerMenu().children.last as? UICommand)
        command.state = .on
        player.validate(command)
        XCTAssertEqual(command.state, .off)
    }
}
