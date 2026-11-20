import CoreGraphics

/// Converts direct finger motion and indirect scroll motion into engine wheel steps.
struct PlayerScrollInput {
    private var remainder: CGFloat = 0
    private let step: CGFloat = 22

    mutating func reset() {
        remainder = 0
    }

    mutating func scroll(by translationY: CGFloat, isDirectTouch: Bool, sendWheel: (Int32) -> Void) {
        // UIKit indirect scroll translation follows content motion. Direct
        // finger drags use the opposite sign for the game's wheel convention.
        remainder += isDirectTouch ? -translationY : translationY
        while remainder >= step {
            remainder -= step
            sendWheel(1)
        }
        while remainder <= -step {
            remainder += step
            sendWheel(-1)
        }
    }
}
