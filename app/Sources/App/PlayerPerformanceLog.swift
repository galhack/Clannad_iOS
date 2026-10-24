import Darwin
import Foundation

/// Opt-in, five-second samples for physical-device comparisons. CPU is the
/// process's user + system time, expressed as a percentage of one CPU core.
final class PlayerPerformanceLog {
    static let enabled = ProcessInfo.processInfo.environment["CLANNAD_PERF_LOG"] == "1"
    private var startedAt: TimeInterval?
    private var startedCPU: Double = 0
    private var startedFrames: UInt32 = 0
    private var callbacks = 0

    func record(at now: TimeInterval, frameCount: UInt32) {
        guard Self.enabled else { return }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        guard let start = startedAt else {
            startedAt = now
            startedCPU = cpu
            startedFrames = frameCount
            return
        }
        callbacks += 1
        let elapsed = now - start
        guard elapsed >= 5 else { return }
        NSLog("[CLANNAD_PERF] seconds=%.2f cpu_one_core_pct=%.2f callbacks_s=%.2f engine_frames_s=%.2f thermal=%d low_power=%d",
              elapsed, (cpu - startedCPU) / elapsed * 100, Double(callbacks) / elapsed,
              Double(frameCount &- startedFrames) / elapsed,
              ProcessInfo.processInfo.thermalState.rawValue,
              ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)
        startedAt = now
        startedCPU = cpu
        startedFrames = frameCount
        callbacks = 0
    }
}
