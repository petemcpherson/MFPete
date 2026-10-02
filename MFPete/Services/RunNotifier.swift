import MFPeteCore
import OSLog

/// Receives run results from `EngineController`. Phase 6 posts them as
/// summary notifications (spec §8.8); until then they are only logged.
protocol RunNotifier {
    func runFinished(_ summary: RunSummary)
    func loopDetected(_ alert: LoopAlert)
}

struct LoggingRunNotifier: RunNotifier {
    private let logger = Logger(subsystem: "com.mftpete.MFPete", category: "Notifications")

    func runFinished(_ summary: RunSummary) {
        logger.info("Run finished: \(summary.ruleName, privacy: .public) acted on \(summary.actedOn) files, \(summary.failed) failed")
    }

    func loopDetected(_ alert: LoopAlert) {
        logger.error("\(alert.message, privacy: .public)")
    }
}
