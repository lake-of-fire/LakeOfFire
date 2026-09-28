import Foundation

/// Serial, lossless full-inventory refreshes. Requests coalesce by storage scope,
/// not by dropping notifications received while a scan or throttle is active.
@MainActor
final class ReaderFileRefreshQueue {
    @MainActor
    final class Completion {
        private var finished: Bool
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        init(finished: Bool = false) { self.finished = finished }

        func wait() async {
            guard !finished, !Task.isCancelled else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                guard !finished, !Task.isCancelled else { return }
                await withCheckedContinuation { waiters[id] = $0 }
            } onCancel: {
                // Only this waiter is cancelled, not the shared scan or another
                // caller coalesced into its completion.
                Task { @MainActor [weak self] in self?.cancelWaiter(id) }
            }
        }

        private func cancelWaiter(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume()
        }

        fileprivate func finish() {
            guard !finished else { return }
            finished = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private struct Request {
        let scope: String
        var force: Bool
        var operation: @MainActor () async -> Void
        var completions: [Completion]
    }

    private let interval: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var pending: [Request] = []
    private var inFlight: Request?
    private var driver: Task<Void, Never>?
    private var delay: Task<Void, Error>?
    private var lastStartedAt: TimeInterval?
    private var isSuspended = false

    init(
        interval: TimeInterval = 2,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        precondition(interval.isFinite && (0...60).contains(interval))
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    @discardableResult
    func enqueue(
        scope: String,
        force: Bool,
        operation: @escaping @MainActor () async -> Void
    ) -> Completion {
        guard !Task.isCancelled else { return Completion(finished: true) }
        let completion: Completion
        if let index = pending.firstIndex(where: { $0.scope == scope }) {
            pending[index].force = pending[index].force || force
            pending[index].operation = operation
            completion = pending[index].completions[0]
        } else {
            completion = Completion()
            pending.append(Request(scope: scope, force: force, operation: operation,
                                   completions: [completion]))
        }
        // Wake only the throttle. Never cancel an in-progress filesystem/Realm
        // scan on behalf of a different waiter.
        if force { delay?.cancel() }
        startIfNeeded()
        return completion
    }

    func waitForIdle() async {
        // A resumed lifecycle can install a successor driver as the cancelled
        // predecessor unwinds. Do not return before that successor has drained.
        while let driver { await driver.value }
    }

    func suspend() {
        isSuspended = true
        delay?.cancel()
        driver?.cancel()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        lastStartedAt = nil
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard driver == nil, !isSuspended, !pending.isEmpty else { return }
        driver = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer {
            // Cancellation does not consume the scan. A newer pending request
            // for its scope already subsumes it; otherwise replay it on resume.
            if let inFlight {
                if let index = pending.firstIndex(where: { $0.scope == inFlight.scope }) {
                    pending[index].completions += inFlight.completions
                } else {
                    pending.insert(inFlight, at: 0)
                }
            }
            inFlight = nil
            delay = nil
            driver = nil
            startIfNeeded()
        }
        while !isSuspended, !Task.isCancelled, !pending.isEmpty {
            // A forced refresh must not remain behind another scope's throttle.
            let index = pending.firstIndex(where: { $0.force }) ?? 0
            if !pending[index].force, let lastStartedAt {
                let remaining = min(interval, max(0, interval - (now() - lastStartedAt)))
                if remaining > 0 {
                    let sleep = self.sleep
                    let wait = Task { try await sleep(remaining) }
                    delay = wait
                    do {
                        try await wait.value
                    } catch {
                        delay = nil
                        if Task.isCancelled || isSuspended { return }
                        // A forced request interrupted the throttle. Re-evaluate
                        // pending work instead of discarding that request.
                        continue
                    }
                    delay = nil
                    if Task.isCancelled || isSuspended { return }
                    // Pending force/operation values may have changed while asleep.
                    continue
                }
            }
            inFlight = pending.remove(at: index)
            lastStartedAt = now()
            await inFlight?.operation()
            if Task.isCancelled || isSuspended { return }
            // Finish this batch's callers even if later notifications keep the
            // queue busy. Waiting for global idle would starve book-open/import.
            for completion in inFlight?.completions ?? [] { completion.finish() }
            inFlight = nil
        }
    }
}
