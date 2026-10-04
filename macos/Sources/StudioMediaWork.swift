import Foundation

// Shared work has independent consumers. Cancelling a card/seek resolves that
// consumer immediately; only the last consumer cancels the underlying transfer.
// A cancelled running job keeps its slot until it actually releases resources.
@MainActor final class StudioMediaWork<Key: Hashable, Value> {
    private final class Job {
        let id = UUID()
        let operation: () async throws -> Value
        var consumers: [UUID: StudioMediaResult<Value>] = [:]
        var task: Task<Void, Never>?
        init(operation: @escaping () async throws -> Value) { self.operation = operation }
    }
    private let limit: Int
    private var jobs: [Key: Job] = [:]
    private var queued: [(Key, UUID)] = []
    private var running = Set<UUID>()
    init(limit: Int) { self.limit = max(1, limit) }

    func value(for key: Key, operation: @escaping () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let consumerID = UUID(), result = StudioMediaResult<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                result.start(continuation)
                guard !Task.isCancelled else { result.finish(.failure(CancellationError())); return }
                let job: Job
                if let current = jobs[key] { job = current }
                else {
                    job = Job(operation: operation); jobs[key] = job
                    queued.append((key, job.id))
                }
                job.consumers[consumerID] = result
                startQueued()
            }
        }, onCancel: {
            // No actor hop is needed to unblock the cancelled caller.
            result.finish(.failure(CancellationError()))
            Task { @MainActor [weak self] in self?.cancel(key, consumer: consumerID) }
        })
    }
    private func cancel(_ key: Key, consumer: UUID) {
        guard let job = jobs[key], job.consumers.removeValue(forKey: consumer) != nil else { return }
        guard job.consumers.isEmpty else { return }
        jobs.removeValue(forKey: key)
        job.task?.cancel()
        if job.task == nil { queued.removeAll { $0.1 == job.id } }
        startQueued()
    }
    func cancelAll() {
        let active = Array(jobs.values)
        jobs.removeAll(); queued.removeAll()
        for job in active {
            for consumer in job.consumers.values { consumer.finish(.failure(CancellationError())) }
            job.consumers.removeAll(); job.task?.cancel()
        }
    }
    private func startQueued() {
        while running.count < limit, !queued.isEmpty {
            let (key, id) = queued.removeFirst()
            guard let job = jobs[key], job.id == id else { continue }
            job.consumers = job.consumers.filter { !$0.value.isCancelled }
            guard !job.consumers.isEmpty else { jobs.removeValue(forKey: key); continue }
            running.insert(id)
            job.task = Task { [weak self] in
                let result: Result<Value, Error>
                do {
                    try Task.checkCancellation()
                    let value = try await job.operation()
                    try Task.checkCancellation()
                    result = .success(value)
                } catch { result = .failure(error) }
                guard let self else { return }
                self.running.remove(id)
                if self.jobs[key]?.id == id {
                    self.jobs.removeValue(forKey: key)
                    for consumer in job.consumers.values { consumer.finish(result) }
                }
                self.startQueued()
            }
        }
    }
}

private final class StudioMediaResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .failure(let error) = outcome { return error is CancellationError }
        return false
    }
    func start(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ outcome: Result<Value, Error>) {
        lock.lock()
        guard self.outcome == nil else { lock.unlock(); return }
        self.outcome = outcome
        let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: outcome)
    }
}
