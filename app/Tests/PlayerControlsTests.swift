import XCTest
import UIKit
@testable import Clannad

@MainActor
final class PlayerControlsTests: XCTestCase {
    func testMenuButtonHitInvokesOnlyMenuAction() throws {
        let bar = PlayerControlBar()
        bar.frame.size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bar.layoutIfNeeded()
        let menu = try XCTUnwrap(button(in: bar, identifier: "player.menu"))
        var menuCalls = 0
        var skipCalls = 0
        bar.onMenu = { menuCalls += 1 }
        bar.onFastForward = { skipCalls += 1 }

        let centre = menu.convert(CGPoint(x: menu.bounds.midX, y: menu.bounds.midY), to: bar)
        let hit = try XCTUnwrap(bar.hitTest(centre, with: nil))
        XCTAssertTrue(hit === menu || hit.isDescendant(of: menu))
        menu.sendActions(for: .touchUpInside)
        XCTAssertEqual(menuCalls, 1)
        XCTAssertEqual(skipCalls, 0)
        XCTAssertEqual(menu.configuration?.title, "菜单")
    }

    func testVisionControlBarContainsOnlyMenuAndReleasesRemovedButtonArea() {
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let bar = PlayerControlBar(showsFastForward: false)
        let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bar.frame = CGRect(x: canvas.bounds.maxX - size.width, y: 0, width: size.width, height: size.height)
        canvas.addSubview(bar)
        bar.layoutIfNeeded()
        XCTAssertNotNil(button(in: bar, identifier: "player.menu"))
        XCTAssertNil(button(in: bar, identifier: "player.skip"))
        XCTAssertEqual(size.width, size.height)
        let freedPoint = CGPoint(x: bar.frame.minX - 32, y: bar.frame.midY)
        XCTAssertTrue(canvas.hitTest(freedPoint, with: nil) === canvas)
        XCTAssertNil(bar.hitTest(CGPoint(x: 2, y: 2), with: nil))
    }

    func testControlDescendantTouchesDoNotReachGameGestures() {
        let button = UIButton(type: .system)
        let content = UILabel()
        button.addSubview(content)
        XCTAssertFalse(SiglusPlayerViewController.acceptsGameTouch(from: content))
    }

    func testGameCanvasTouchesStillReachGameGestures() {
        let canvas = UIView()
        let content = UIView()
        canvas.addSubview(content)
        XCTAssertTrue(SiglusPlayerViewController.acceptsGameTouch(from: content))
    }

    func testMenuGestureCanReachChoiceButtonsWhileSingleTapStaysInUIKit() {
        let panel = PlayerChoicePanel(choices: ["前往中庭", "还是算了"], canCancel: false)
        let button = self.button(in: panel, identifier: "player.choice.0")!
        XCTAssertTrue(SiglusPlayerViewController.acceptsGameTouch(from: button, menuGesture: true))
        XCTAssertFalse(SiglusPlayerViewController.acceptsGameTouch(from: button))
    }

    func testTwoFingerMenuGestureCancelsUnderlyingChoiceTouches() throws {
        let player = SiglusPlayerViewController(gameRoot: URL(fileURLWithPath: "/unused"),
                                               title: "Test", onExit: {})
        player.loadViewIfNeeded()
        let menu = try XCTUnwrap(player.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.numberOfTouchesRequired == 2 })
        XCTAssertTrue(menu.cancelsTouchesInView)
    }

    func testFastForwardButtonReportsOnAndOff() throws {
        let bar = PlayerControlBar()
        let skip = try XCTUnwrap(button(in: bar, identifier: "player.skip"))
        bar.setFastForwardActive(true)
        XCTAssertEqual(skip.accessibilityValue, "开启")
        bar.setFastForwardActive(false)
        XCTAssertEqual(skip.accessibilityValue, "关闭")
    }

    func testSystemInterfaceLeavesOriginalCloseButtonTouchable() throws {
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let close = UIButton(frame: CGRect(x: 900, y: 20, width: 100, height: 80))
        canvas.addSubview(close)
        let bar = PlayerControlBar()
        bar.frame = CGRect(origin: CGPoint(x: 830, y: 20),
                           size: bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
        canvas.addSubview(bar)
        bar.layoutIfNeeded()
        let skip = try XCTUnwrap(button(in: bar, identifier: "player.skip"))
        let point = skip.convert(CGPoint(x: skip.bounds.midX, y: skip.bounds.midY), to: canvas)
        XCTAssertFalse(canvas.hitTest(point, with: nil) === close)

        bar.setSystemInterfaceActive(true)
        XCTAssertTrue(canvas.hitTest(point, with: nil) === close)

        bar.setSystemInterfaceActive(false)
        let hit = try XCTUnwrap(canvas.hitTest(point, with: nil))
        XCTAssertTrue(hit === skip || hit.isDescendant(of: skip))
    }

    func testHiddenPreferenceSurvivesSystemMenuRoundTrip() {
        let bar = PlayerControlBar()
        bar.setButtonsVisible(false)
        bar.setSystemInterfaceActive(true)
        bar.setSystemInterfaceActive(false)
        XCTAssertTrue(bar.isHidden)
    }

    func testEnablingButtonsInsideSystemMenuWaitsUntilMenuCloses() {
        let bar = PlayerControlBar()
        bar.setButtonsVisible(false)
        bar.setSystemInterfaceActive(true)
        bar.setButtonsVisible(true)
        XCTAssertTrue(bar.isHidden)
        bar.setSystemInterfaceActive(false)
        XCTAssertFalse(bar.isHidden)
    }

    private func button(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0, identifier: identifier) }.first
    }
}
