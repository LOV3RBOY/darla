import Foundation
import MetricKit
import UIKit

/// Self-contained crash forensics: MetricKit crash diagnostics + a rolling breadcrumb log with memory footprint.
/// If the previous session didn't end cleanly, `pendingReport` holds a copyable summary on the next launch.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    private let dir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var crumbs: [String] = []
    private let lock = NSLock()
    private var timer: Timer?
    private var peakMB: Double = 0
    private(set) var pendingReport: String?

    private var crumbsURL: URL { dir.appendingPathComponent("breadcrumbs.txt") }
    private var prevCrumbsURL: URL { dir.appendingPathComponent("breadcrumbs.prev.txt") }
    private var runningURL: URL { dir.appendingPathComponent("session.running") }
    private var mxURL: URL { dir.appendingPathComponent("metrickit.txt") }

    func start() {
        let fm = FileManager.default
        let crashedLastTime = fm.fileExists(atPath: runningURL.path)
        if fm.fileExists(atPath: crumbsURL.path) {
            try? fm.removeItem(at: prevCrumbsURL)
            try? fm.moveItem(at: crumbsURL, to: prevCrumbsURL)
        }
        if crashedLastTime { buildReport() }
        fm.createFile(atPath: runningURL.path, contents: Data())
        MXMetricManager.shared.add(self)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("MEMORY WARNING at \(Self.footprintMB()) MB")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.markClean()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            FileManager.default.createFile(atPath: self.runningURL.path, contents: Data())
        }
        let device = UIDevice.current
        log("launch · \(device.systemName) \(device.systemVersion) · \(Self.model()) · build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")")
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    func markClean() {
        try? FileManager.default.removeItem(at: runningURL)
        flush()
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        lock.lock()
        crumbs.append("\(f.string(from: Date())) \(s)")
        if crumbs.count > 300 { crumbs.removeFirst(crumbs.count - 300) }
        lock.unlock()
    }

    private func sample() {
        let mb = Self.footprintMB()
        peakMB = max(peakMB, mb)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "cool"; case .fair: thermal = "warm"; case .serious: thermal = "HOT"; case .critical: thermal = "CRITICAL"; @unknown default: thermal = "?" }
        log(String(format: "mem %.0f MB (peak %.0f) · %@", mb, peakMB, thermal))
        flush()
    }

    private func flush() {
        lock.lock(); let text = crumbs.joined(separator: "\n"); lock.unlock()
        try? text.data(using: .utf8)?.write(to: crumbsURL, options: .atomic)
    }

    private func buildReport() {
        var out = "DARLA crash report\n"
        if let mx = try? String(contentsOf: mxURL, encoding: .utf8), !mx.isEmpty { out += "\n— Apple diagnostics —\n" + mx.suffix(6000) + "\n" }
        if let prev = try? String(contentsOf: prevCrumbsURL, encoding: .utf8) {
            let lines = prev.split(separator: "\n").suffix(60)
            out += "\n— Last moments —\n" + lines.joined(separator: "\n")
        }
        pendingReport = out
    }

    func clearReport() { pendingReport = nil; try? FileManager.default.removeItem(at: mxURL) }

    // MARK: MetricKit — crash diagnostics arrive on a later launch

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var text = ""
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                text += "CRASH \(c.metaData.applicationBuildVersion) · type \(c.exceptionType?.stringValue ?? "-") code \(c.exceptionCode?.stringValue ?? "-") signal \(c.signal?.stringValue ?? "-")\n"
                if let r = c.terminationReason { text += "reason: \(r)\n" }
                if let reason = c.exceptionReason { text += "exception: \(reason.composedMessage)\n" }
                if let s = String(data: c.callStackTree.jsonRepresentation(), encoding: .utf8) { text += "stack: " + String(s.prefix(3000)) + "\n" }
            }
            for h in p.hangDiagnostics ?? [] { text += "HANG \(h.hangDuration)\n" }
            for d in p.diskWriteExceptionDiagnostics ?? [] { text += "DISK \(d.totalWritesCaused)\n" }
        }
        guard !text.isEmpty else { return }
        let prior = (try? String(contentsOf: mxURL, encoding: .utf8)) ?? ""
        try? (prior + text).data(using: .utf8)?.write(to: mxURL, options: .atomic)
        DispatchQueue.main.async {
            if self.pendingReport == nil { self.pendingReport = "DARLA crash report\n\n— Apple diagnostics —\n" + text }
            NotificationCenter.default.post(name: .darlaDiagnostics, object: nil)
        }
    }

    // MARK: helpers

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func model() -> String {
        var sys = utsname(); uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

extension Notification.Name { static let darlaDiagnostics = Notification.Name("darlaDiagnostics") }
