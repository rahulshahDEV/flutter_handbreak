import Foundation
import AVFoundation

/// Job lifecycle — mirrors HandBrake's HB_STATE_WORKING → done/error with
/// exactly-once completion, bounded concurrency (one native encode at a time),
/// and cancellation hooks into AVAssetExportSession / AVAssetWriter.
final class Job {
    let id: String
    var isCancelled = false
    var task: AnyObject?                       // cancellable object (export session / writer)
    var progressSink: (([String: Any]) -> Void)?

    var finished = false
    var resultPayload: [String: Any]?
    var errorPayload: [String: Any]?
    var continuation: (([String: Any]) -> Void)?

    init(id: String = UUID().uuidString) { self.id = id }
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
            j.isCancelled = true
            if let s = j.task as? AVAssetExportSession { s.cancelExport() }
            if let w = j.task as? AVAssetWriter { w.cancelWriting() }
        }
    }

    func cancelAll() {
        lock.lock(); let all = Array(jobs.keys); lock.unlock()
        all.forEach { cancel(jobId: $0) }
    }

    func dispose(jobId: String) {
        lock.lock(); jobs.removeValue(forKey: jobId); lock.unlock()
    }

    func emitProgress(_ job: Job, _ payload: [String: Any]) {
        lock.lock()
        let cancelled = job.isCancelled
        let sink = job.progressSink
        lock.unlock()
        guard !cancelled else { return }
        sink?(payload)
    }

    func startVideo(job: Job, inputPath: String, outputPath: String, options: [String: Any]) {
        runSerialized {
            VideoPipeline.run(job: job, manager: self, inputPath: inputPath,
                              outputPath: outputPath, options: options)
        }
    }

    func startImage(job: Job, inputPath: String, outputPath: String, options: [String: Any]) {
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
        sink?(["error": err])
        cont?(["error": err])
    }
}
