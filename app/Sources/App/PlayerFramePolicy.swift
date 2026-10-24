import Foundation

enum PlayerFramePolicy {
    /// A visual novel does not need ProMotion-rate scene composition. Keep
    /// the full drawable resolution, and reduce cadence further under pressure.
    static func framesPerSecond(thermalState: ProcessInfo.ThermalState, lowPower: Bool) -> Float {
        if thermalState == .critical { return 15 }
        if thermalState == .serious || lowPower { return 20 }
        return 30
    }
}
