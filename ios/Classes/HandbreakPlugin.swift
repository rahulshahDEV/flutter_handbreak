import Flutter
import UIKit

/// Handbreak plugin — MethodChannel dispatch + per-job progress EventChannels.
///
/// Fixes audit P0-4/P0-5: clean ProgressStreamHandler (no inout/pointer hacks),
/// UIKit imported, sinks guarded by lock, jobs completed exactly once.
public class HandbreakPlugin: NSObject, FlutterPlugin {

    private var registrar: FlutterPluginRegistrar?
    private let manager = JobManager()
    private let lock = NSLock()
    private var channels: [String: FlutterEventChannel] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "handbreak", binaryMessenger: registrar.messenger())
        let instance = HandbreakPlugin()
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        manager.cancelAll()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getHardwareCapabilities":
            // Audit P1-10: VTCompressionSession probes are expensive and must
            // never run on the platform/main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let caps = HardwareCapabilitiesProvider.get()
                DispatchQueue.main.async { result(caps) }
            }

        case "probe":
            guard let args = call.arguments as? [String: Any],
                  let path = args["inputPath"] as? String else {
                result(FlutterError(code: "INVALID_INPUT", message: "inputPath required", details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard self != nil else { result(nil); return }
                do {
                    let info = try MediaProbe.probe(path: path)
                    DispatchQueue.main.async { result(info) }
                } catch let e as ProbeError {
                    DispatchQueue.main.async { result(FlutterError(code: e.code, message: e.message, details: nil)) }
                } catch {
                    DispatchQueue.main.async { result(FlutterError(code: "UNSUPPORTED_FORMAT", message: error.localizedDescription, details: nil)) }
                }
            }

        case "startVideoCompression":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_INPUT", message: "inputPath/outputPath required", details: nil))
                return
            }
            let options = args["options"] as? [String: Any] ?? [:]
            startJob(result: result) { job in
                self.manager.startVideo(job: job, inputPath: inputPath, outputPath: outputPath, options: options)
            }

        case "startImageCompression":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_INPUT", message: "inputPath/outputPath required", details: nil))
                return
            }
            let options = args["options"] as? [String: Any] ?? [:]
            startJob(result: result) { job in
                self.manager.startImage(job: job, inputPath: inputPath, outputPath: outputPath, options: options)
            }

        case "waitForResult":
            guard let args = call.arguments as? [String: Any], let jobId = args["jobId"] as? String else {
                result(FlutterError(code: "INVALID_INPUT", message: "jobId required", details: nil))
                return
            }
            manager.waitForResult(jobId: jobId) { payload in
                DispatchQueue.main.async { result(payload) }
            }

        case "cancelJob":
            if let args = call.arguments as? [String: Any], let jobId = args["jobId"] as? String {
                manager.cancel(jobId: jobId)
            }
            result(nil)

        case "disposeJob":
            if let args = call.arguments as? [String: Any], let jobId = args["jobId"] as? String {
                manager.dispose(jobId: jobId)
                lock.lock()
                channels.removeValue(forKey: jobId)?.setStreamHandler(nil)
                lock.unlock()
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startJob(result: @escaping FlutterResult, launch: @escaping (Job) -> Void) {
        let job = manager.createJob()
        registerProgressChannel(jobId: job.id)
        launch(job)
        result(job.id)
    }

    private func registerProgressChannel(jobId: String) {
        guard let messenger = registrar?.messenger() else { return }
        let channel = FlutterEventChannel(name: "handbreak/progress/\(jobId)", binaryMessenger: messenger)
        channel.setStreamHandler(ProgressStreamHandler(
            onListen: { [weak self] sink in
                self?.manager.setProgressSink(jobId: jobId, sink: { payload in
                    DispatchQueue.main.async { sink(payload) }
                })
            },
            onCancel: { [weak self] in
                self?.manager.setProgressSink(jobId: jobId, sink: nil)
            }))
        lock.lock()
        channels[jobId] = channel
        lock.unlock()
    }
}

/// Clean stream handler — no inout capture, no unsafe pointers.
private final class ProgressStreamHandler: NSObject, FlutterStreamHandler {
    private let onListen: (@escaping FlutterEventSink) -> Void
    private let onCancel: () -> Void

    init(onListen: @escaping (@escaping FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
        self.onListen = onListen
        self.onCancel = onCancel
        super.init()
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListen(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancel()
        return nil
    }
}
