import Foundation
import AVFoundation

/// Formal job states (spec §5) — exactly-once terminal transitions.
enum JobState: String, CaseIterable {
    case created = "CREATED"
    case queued = "QUEUED"
    case probing = "PROBING"
    case planning = "PLANNING"
    case initializing = "INITIALIZING"
    case running = "RUNNING"
    case draining = "DRAINING"
    case validating = "VALIDATING"
    case committing = "COMMITTING"
    case completed = "COMPLETED"
    case cancelling = "CANCELLING"
    case cancelled = "CANCELLED"
    case failed = "FAILED"
    case disposed = "DISPOSED"
}

/// Job lifecycle — deterministic state transitions, exactly-once completion,
/// idempotent cancellation/disposal, and *synchronized* access to the
/// cancellable task (audit P1-9: the pipeline writes `task` while `cancel`
/// reads it — a data race under ThreadSanitizer).
final class Job {
    let id: String
    private let taskLock = NSLock()
    private var cancellableTask: AnyObject?   // AVAssetExportSession / AVAssetWriter

    private let stateLock = NSLock()
    private var _state: JobState = .created
    /// 🔴-4: request vs terminal distinction. Set synchronously on cancel;
    /// pipelines and progress use it as the cooperative stop signal.
    private let cancelRequestedLock = NSLock()
    private var _cancelRequested = false

    var progressSink: (([String: Any]) -> Void)?
    var finished = false
    var resultPayload: [String: Any]?
    var errorPayload: [String: Any]?
    var continuation: (([String: Any]) -> Void)?

    init(id: String = UUID().uuidString) { self.id = id }

    // MARK: - synchronized task access (audit P1-9)

    func setTask(_ t: AnyObject?) {
        taskLock.lock(); cancellableTask = t; taskLock.unlock()
    }

    /// Runs `body` with the current cancellable task under lock; returns nothing.
    func withTask(_ body: (AnyObject?) -> Void) {
        taskLock.lock(); body(cancellableTask); taskLock.unlock()
    }

    // MARK: - state machine (audit: illegal transitions rejected, idempotent)

    func transition(to target: JobState, allowedFrom: Set<JobState>) {
        stateLock.lock(); defer { stateLock.unlock() }
        if allowedFrom.contains(_state) { _state = target }
    }

    var state: JobState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    /// Cooperative cancellation checks inside pipelines — true the moment a
    /// cancel is REQUESTED, not only after the terminal transition (🔴-4).
    var isCancelled: Bool {
        cancelRequestedLock.lock(); defer { cancelRequestedLock.unlock() }
        return _cancelRequested
    }

    func requestCancel() {
        cancelRequestedLock.lock()
        _cancelRequested = true
        cancelRequestedLock.unlock()
        transition(to: .cancelling,
                   allowedFrom: [.created, .queued, .probing, .planning,
                                 .initializing, .running, .draining,
                                 .validating, .committing])
    }
}

final class JobManager {
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    /// Mobile thermal/battery budget (spec §24): one native encode at a time.
    private let semaphore = DispatchSemaphore(value: 1)

    func createJob() -> Job {
        let j = Job()
        lock.lock(); jobs[j.id] = j; lock.unlock()
        return j
    }

    private func withJob<T>(_ jobId: String, _ body: (Job) -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        return jobs[jobId].flatMap(body)
    }

    func setProgressSink(jobId: String, sink: (([String: Any]) -> Void)?) {
        _ = withJob(jobId) { $0.progressSink = sink }
    }

    func cancel(jobId: String) {
        withJob(jobId) { j in
            j.requestCancel() // CANCELLING (requested); terminal set on drain
            j.withTask { task in
                if let s = task as? AVAssetExportSession { s.cancelExport() }
                if let w = task as? AVAssetWriter { w.cancelWriting() }
            }
        }
    }

    func cancelAll() {
        lock.lock(); let all = Array(jobs.keys); lock.unlock()
        all.forEach { cancel(jobId: $0) }
    }

    func dispose(jobId: String) {
        // Dispose must also stop any running native work (battery/resource safety).
        cancel(jobId: jobId)
        withJob(jobId) { $0.transition(to: .disposed, allowedFrom: Set(JobState.allCases)) }
        lock.lock(); jobs.removeValue(forKey: jobId); lock.unlock()
    }

    func emitProgress(_ job: Job, _ payload: [String: Any]) {
        lock.lock()
        let cancelled = job.state == .cancelled
        let sink = job.progressSink
        lock.unlock()
        guard !cancelled else { return }
        sink?(payload)
    }

    func startVideo(job: Job, inputPath: String, outputPath: String, options: [String: Any]) {
        job.transition(to: .queued, allowedFrom: [.created])
        runSerialized {
            VideoPipeline.run(job: job, manager: self, inputPath: inputPath,
                              outputPath: outputPath, options: options)
        }
    }

    func startImage(job: Job, inputPath: String, outputPath: String, options: [String: Any]) {
        job.transition(to: .queued, allowedFrom: [.created])
        runSerialized {
            ImagePipeline.run(job: job, manager: self, inputPath: inputPath,
                              outputPath: outputPath, options: options)
        }
    }

    private func runSerialized(_ body: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }
            body()
        }
    }

    /// Single-waiter contract from the Dart bridge; repeated waits get cached payload.
    func waitForResult(jobId: String, completion: @escaping ([String: Any]) -> Void) {
        lock.lock()
        guard let j = jobs[jobId] else {
            lock.unlock()
            completion(["error": ["code": "INVALID_INPUT", "message": "Unknown jobId"]])
            return
        }
        if let r = j.resultPayload { lock.unlock(); completion(r); return }
        if let e = j.errorPayload { lock.unlock(); completion(["error": e]); return }
        j.continuation = completion
        lock.unlock()
    }

    func complete(job: Job, result: [String: Any]) {
        lock.lock()
        guard !job.finished else { lock.unlock(); return }
        job.finished = true
        job.resultPayload = result
        let cont = job.continuation
        job.continuation = nil
        lock.unlock()
        job.transition(to: .completed, allowedFrom: [.queued, .probing, .planning, .initializing, .running, .draining, .validating, .committing, .created])
        cont?(result)
    }

    func fail(job: Job, code: String, message: String) {
        let err = ["code": code, "message": message]
        lock.lock()
        guard !job.finished else { lock.unlock(); return }
        job.finished = true
        job.errorPayload = err
        let cont = job.continuation
        job.continuation = nil
        let sink = job.progressSink
        lock.unlock()
        let terminal: JobState = (code == "CANCELLED") ? .cancelled : .failed
        job.transition(to: terminal, allowedFrom: [.queued, .probing, .planning, .initializing, .running, .draining, .validating, .committing, .created, .cancelling])
        sink?(["error": err])
        cont?(["error": err])
    }
}