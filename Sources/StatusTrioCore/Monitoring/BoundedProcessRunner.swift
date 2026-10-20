import Darwin
import Foundation

/// How a bounded child-process invocation finished.
enum BoundedProcessOutcome: Equatable, Sendable {
    /// The child exited 0; `stdout` is what it wrote (capped at the limit).
    case exited(Data)
    /// The deadline passed. The child was terminated and, failing that, killed.
    case timedOut
    /// The caller cancelled the invocation.
    case cancelled
    /// Launch failed, the child exited non-zero, or a signal killed it.
    case failed
    /// The child wrote more than the limit; it was terminated.
    case outputTooLarge
}

/// Runs one child process with a hard deadline, draining both pipes.
///
/// Exists because `Process.waitUntilExit()` plus `readDataToEndOfFile()` has no
/// bound: a child that never exits, or a grandchild that inherits the pipe and
/// keeps it open, blocks the calling thread for good. On the CoreWLAN and
/// Bluetooth serial queues that is not recoverable - the whole read chain stalls
/// behind it.
///
/// The same state machine serves both callers that can await and callers that
/// cannot: `run` bridges into a checked continuation, `runSync` waits on a
/// semaphore for at most the same deadline. Neither leaves a thread behind.
///
/// Ordering that matters: the deadline is armed *after* `run()` succeeds, an
/// already-exited child with still-open pipes finishes immediately rather than
/// waiting out the grace period, and every exit path resumes exactly once.
final class BoundedProcessInvocation: @unchecked Sendable {
    static let defaultOutputLimit = 1_048_576

    /// How long the child gets between `terminate()` and `SIGKILL`.
    private static let killGrace: DispatchTimeInterval = .milliseconds(250)
    /// How long the pipes get to reach EOF after the child is gone.
    private static let streamGrace: DispatchTimeInterval = .milliseconds(500)

    private let queue = DispatchQueue(label: "StatusTrio.BoundedProcess")
    private let executableURL: URL
    private let arguments: [String]
    private let outputLimit: Int

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdout = Data()
    private var stderrCount = 0
    private var stdoutEnded = false
    private var stderrEnded = false
    private var processEnded = false
    private var hasStarted = false
    private var cancelled = false
    private var failure: BoundedProcessOutcome?
    private var onFinish: ((BoundedProcessOutcome) -> Void)?

    init(executableURL: URL, arguments: [String], outputLimit: Int = BoundedProcessInvocation.defaultOutputLimit) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.outputLimit = outputLimit
    }

    // MARK: - Entry points

    /// Awaits the child, honouring task cancellation.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        outputLimit: Int = BoundedProcessInvocation.defaultOutputLimit
    ) async -> BoundedProcessOutcome {
        let invocation = BoundedProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            outputLimit: outputLimit
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                invocation.start(timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            invocation.cancel()
        }
    }

    /// Blocks the calling thread for at most `timeout`, plus the short grace
    /// periods used to reap the child. For callers on a serial queue that cannot
    /// be made async without reworking their protocol.
    static func runSync(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        outputLimit: Int = BoundedProcessInvocation.defaultOutputLimit
    ) -> BoundedProcessOutcome {
        let invocation = BoundedProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            outputLimit: outputLimit
        )
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: BoundedProcessOutcome?

        invocation.start(timeout: timeout) { outcome in
            lock.withLock { result = outcome }
            semaphore.signal()
        }

        // The state machine always finishes within the deadline plus its own
        // grace periods, so waiting a little past the deadline is enough; the
        // extra second only covers scheduling slack, and the wait is still
        // bounded.
        semaphore.wait(timeout: .now() + seconds(timeout) + 1.5)
        return lock.withLock { result } ?? .timedOut
    }

    // MARK: - State machine

    private func start(timeout: Duration, onFinish: @escaping (BoundedProcessOutcome) -> Void) {
        queue.async {
            self.onFinish = onFinish
            guard !self.cancelled else {
                self.finish(.cancelled)
                return
            }

            let child = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            child.executableURL = self.executableURL
            child.arguments = self.arguments
            child.standardOutput = stdoutPipe
            child.standardError = stderrPipe
            self.process = child
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak invocation = self] handle in
                let data = handle.availableData
                guard let invocation else { return }
                invocation.queue.async { [invocation] in invocation.received(data, stream: .stdout) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak invocation = self] handle in
                let data = handle.availableData
                guard let invocation else { return }
                invocation.queue.async { [invocation] in invocation.received(data, stream: .stderr) }
            }
            child.terminationHandler = { [weak invocation = self] terminated in
                guard let invocation else { return }
                invocation.queue.async { [invocation] in
                    invocation.processEnded = true
                    if terminated.terminationReason != .exit || terminated.terminationStatus != 0 {
                        invocation.failure = invocation.failure ?? .failed
                    }
                    invocation.completeIfReady()
                }
            }

            do {
                try child.run()
                self.hasStarted = true
                self.queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) {
                    guard self.onFinish != nil else { return }
                    self.failure = self.failure ?? .timedOut
                    // The child may already be gone while a descendant still
                    // holds the inherited pipes; the stream-ended flags then
                    // never arrive and the caller would wait forever.
                    if self.processEnded {
                        self.finishWithHeldStreams()
                        return
                    }
                    self.terminateThenKill()
                    self.queue.asyncAfter(deadline: .now() + Self.streamGrace) {
                        self.finishWithHeldStreams()
                    }
                }
            } catch {
                self.failure = .failed
                self.processEnded = true
                self.stdoutEnded = true
                self.stderrEnded = true
                self.completeIfReady()
            }
        }
    }

    func cancel() {
        queue.async {
            guard !self.processEnded else { return }
            self.cancelled = true
            self.failure = .cancelled
            if self.hasStarted {
                self.terminateThenKill()
                self.queue.asyncAfter(deadline: .now() + Self.streamGrace) {
                    self.finishWithHeldStreams()
                }
            } else {
                self.processEnded = true
                self.stdoutEnded = true
                self.stderrEnded = true
                self.completeIfReady()
            }
        }
    }

    private enum Stream { case stdout, stderr }

    private func received(_ data: Data, stream: Stream) {
        if data.isEmpty {
            switch stream {
            case .stdout:
                stdoutEnded = true
                stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            case .stderr:
                stderrEnded = true
                stderrPipe?.fileHandleForReading.readabilityHandler = nil
            }
            completeIfReady()
            return
        }
        switch stream {
        case .stdout:
            guard stdout.count + data.count <= outputLimit else {
                failure = failure ?? .outputTooLarge
                terminateThenKill()
                return
            }
            stdout.append(data)
        case .stderr:
            guard stderrCount + data.count <= outputLimit else {
                failure = failure ?? .outputTooLarge
                terminateThenKill()
                return
            }
            stderrCount += data.count
        }
    }

    private func terminateThenKill() {
        guard let child = process, child.isRunning else { return }
        child.terminate()
        let pid = child.processIdentifier
        queue.asyncAfter(deadline: .now() + Self.killGrace) {
            guard child.isRunning else { return }
            _ = kill(pid, SIGKILL)
        }
    }

    /// Finishes an invocation whose child is gone but whose pipes are still open
    /// in a descendant. The deadline (or the caller's cancellation) already
    /// passed, so any partial output is dropped rather than leaving the caller
    /// waiting for the descendant's lifetime.
    private func finishWithHeldStreams() {
        guard onFinish != nil else { return }
        failure = failure ?? .timedOut
        processEnded = true
        stdoutEnded = true
        stderrEnded = true
        completeIfReady()
    }

    private func completeIfReady() {
        guard processEnded, stdoutEnded, stderrEnded, onFinish != nil else { return }
        finish(failure ?? .exited(stdout))
    }

    private func finish(_ outcome: BoundedProcessOutcome) {
        guard let onFinish else { return }
        self.onFinish = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        stdoutPipe = nil
        stderrPipe = nil
        process?.terminationHandler = nil
        process = nil
        onFinish(outcome)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
