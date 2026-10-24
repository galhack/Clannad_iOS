import XCTest
import UIKit
@testable import Clannad

@MainActor
final class PlayerChoicesTests: XCTestCase {
    func testChoosingSecondVisibleOptionReportsSecondIndex() throws {
        let panel = PlayerChoicePanel(choices: ["First route", "Second route"], canCancel: false)
        var selected: Int?
        panel.onSelect = { selected = $0 }
        let button = try XCTUnwrap(findButton(panel, id: "player.choice.1"))
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, 1)
    }

    func testChineseChoiceHitPointsKeepDisplayedOrder() throws {
        let panel = PlayerChoicePanel(choices: ["前往中庭", "还是算了"], canCancel: false)
        panel.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        panel.layoutIfNeeded()
        var selected: [Int] = []
        panel.onSelect = { selected.append($0) }
        for index in 0..<2 {
            let button = try XCTUnwrap(findButton(panel, id: "player.choice.\(index)"))
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: panel)
            let hit = try XCTUnwrap(panel.hitTest(point, with: nil))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button))
            button.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(selected, [0, 1])
    }

    func testChoiceButtonsHaveASeparateNonSelectingGap() throws {
        let panel = PlayerChoicePanel(choices: ["前往中庭", "还是算了"], canCancel: false)
        panel.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        panel.layoutIfNeeded()
        let first = try XCTUnwrap(findButton(panel, id: "player.choice.0"))
        let second = try XCTUnwrap(findButton(panel, id: "player.choice.1"))
        let firstRect = first.convert(first.bounds, to: panel)
        let secondRect = second.convert(second.bounds, to: panel)
        XCTAssertGreaterThanOrEqual(secondRect.minY - firstRect.maxY, 32)
        let gap = CGPoint(x: firstRect.midX, y: (firstRect.maxY + secondRect.minY) / 2)
        let hit = try XCTUnwrap(panel.hitTest(gap, with: nil))
        XCTAssertFalse(hit === first || hit.isDescendant(of: first) || hit === second || hit.isDescendant(of: second))
    }

    func testChoicePanelBackgroundCannotReachGameGestures() {
        let panel = PlayerChoicePanel(choices: ["First route"], canCancel: false)
        XCTAssertFalse(SiglusPlayerViewController.acceptsGameTouch(from: panel))
    }

    func testCancelIsAvailableOnlyForCancelableSelections() {
        let panel = PlayerChoicePanel(choices: ["First route"], canCancel: false)
        XCTAssertNil(findButton(panel, id: "player.choice.cancel"))
        let cancelable = PlayerChoicePanel(choices: ["First route"], canCancel: true)
        XCTAssertNotNil(findButton(cancelable, id: "player.choice.cancel"))
    }

    func testShortChoiceListUsesACompactCard() throws {
        let panel = PlayerChoicePanel(choices: ["First route", "Second route"], canCancel: false)
        panel.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        panel.layoutIfNeeded()
        let card = try XCTUnwrap(panel.subviews.first as? UIScrollView)
        XCTAssertLessThan(card.bounds.height, panel.bounds.height * 0.5)
    }

    func testLongChoiceListScrollsWithinTheScreen() throws {
        let panel = PlayerChoicePanel(choices: (0..<20).map { "Route \($0)" }, canCancel: false)
        panel.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        panel.layoutIfNeeded()
        let card = try XCTUnwrap(panel.subviews.first as? UIScrollView)
        XCTAssertGreaterThan(card.contentSize.height, card.bounds.height)
    }

    private func findButton(_ view: UIView, id: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        return view.subviews.lazy.compactMap { self.findButton($0, id: id) }.first
    }
}
