import Foundation
import os.log
import Combine
import Darwin

/// App-wide event log, observable for SwiftUI. Any view/service can append a
/// line via `AppLogger.shared.log("event description", category: "xxx")`. The
/// debug log sheet in `WorkoutView` reads `lines` and renders them.
///
/// Lines are persisted to `Documents/debug.log` so the history survives app
/// launches — the user can run the app for days and then share the file with
/// me for review. Lines are also forwarded to Apple's unified logging
/// (`os.Logger`) so the same events show up in Console.app when attached.
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    /// In-memory tail used for UI rendering. Capped at `maxLinesInMemory` to
    /// keep the debug-log sheet responsive even after long usage.
    @Published private(set) var lines: [String] = []

    /// On-disk file URL — exposed so the sheet can show a `ShareLink`.
    let logFileURL: URL

    private let osLogger = Logger(subsystem: "com.abhaygulati.fittrack.ag2026", category: "app")
    private static let maxLinesInMemory = 1000
    private static let maxFileBytes: UInt64 = 10 * 1024 * 1024  // 10 MB hard cap

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let writeQueue = DispatchQueue(label: "com.abhaygulati.fittrack.applogger", qos: .utility)

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.logFileURL = docs.appendingPathComponent("debug.log")
        loadTailFromDisk()
        // Write a session boundary so a crash in the previous launch is
        // visually obvious in the log file.
        let separator = "========= NEW SESSION \(Self.timeFormatter.string(from: Date())) ========="
        if Thread.isMainThread { append(separator) } else { DispatchQueue.main.async { [weak self] in self?.append(separator) } }
        writeQueue.async { [weak self] in self?.appendToFile(separator) }
        log("AppLogger initialized — log file at \(logFileURL.path)", category: "app")
    }

    /// Append a line. Safe to call from any thread — coalesces onto main for
    /// the in-memory buffer; file writes happen on a serial utility queue.
    func log(_ message: String, category: String = "app") {
        let line = "[\(Self.timeFormatter.string(from: Date()))] [\(category)] \(message)"
        osLogger.info("\(line, privacy: .public)")

        if Thread.isMainThread {
            append(line)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(line) }
        }

        writeQueue.async { [weak self] in self?.appendToFile(line) }
    }

    func clear() {
        let action: () -> Void = { [weak self] in self?.lines.removeAll() }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }

        writeQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.maxLinesInMemory {
            lines.removeFirst(lines.count - Self.maxLinesInMemory)
        }
    }

    // MARK: - Disk

    private func loadTailFromDisk() {
        guard let data = try? Data(contentsOf: logFileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = allLines.suffix(Self.maxLinesInMemory)
        self.lines = Array(tail)
    }

    private func appendToFile(_ line: String) {
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        let fm = FileManager.default

        // Soft rotation: if the file exceeds the cap, truncate the head by
        // re-writing only the last 5 MB so we don't lose the most recent
        // history. Cheap because it only runs after the cap is breached.
        if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > Self.maxFileBytes {
            rotateFile()
        }

        if fm.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
            }
        } else {
            try? payload.write(to: logFileURL, options: .atomic)
        }
    }

    private func rotateFile() {
        guard let data = try? Data(contentsOf: logFileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Keep approximately the second half so we end up well under the cap.
        let keep = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? keep.data(using: .utf8)?.write(to: logFileURL, options: .atomic)
    }

    // MARK: - Crash capture

    /// Wire NSException + POSIX signal handlers so a crash gets a final line
    /// in `debug.log` before the process dies. Call once from app launch —
    /// further calls are no-ops.
    ///
    /// Signal handlers must be async-signal-safe: no Foundation, no Swift
    /// allocations, no Objective-C runtime. We pre-open the log fd here and
    /// use POSIX `write(2)` from the handler. The exception handler runs
    /// *before* the abort so it can use Foundation freely.
    func installCrashHandlers() {
        Self.installCrashHandlersOnce()
        log("crash handlers installed", category: "app")
    }

    private static var crashHandlersInstalled = false
    fileprivate static var crashLogFD: Int32 = -1

    private static func installCrashHandlersOnce() {
        guard !crashHandlersInstalled else { return }
        crashHandlersInstalled = true

        // Pre-open the log file so the signal handler doesn't have to call
        // `open` (it's async-signal-safe but allocates a path string).
        let path = AppLogger.shared.logFileURL.path
        crashLogFD = path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }

        NSSetUncaughtExceptionHandler { exception in
            let line = "!!! UNCAUGHT EXCEPTION name=\(exception.name.rawValue) reason=\(exception.reason ?? "nil")\n"
            let stack = "stack: " + exception.callStackSymbols.joined(separator: " | ") + "\n"
            // Use POSIX write — Foundation is technically OK in an exception
            // handler but we may already be in a degraded state.
            if AppLogger.crashLogFD >= 0 {
                _ = line.withCString { Darwin.write(AppLogger.crashLogFD, $0, strlen($0)) }
                _ = stack.withCString { Darwin.write(AppLogger.crashLogFD, $0, strlen($0)) }
                fsync(AppLogger.crashLogFD)
            }
        }

        // Hook the common fatal signals. We do NOT hook SIGKILL/SIGSTOP
        // (uncatchable) or SIGTERM (we want clean shutdown).
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE, SIGTRAP]
        for sig in signals {
            signal(sig) { sig in
                // Async-signal-safe path: no Foundation, no Swift String
                // interpolation that would allocate. We hand-format a fixed
                // prefix and the signal number.
                let prefix = "!!! SIGNAL "
                _ = prefix.withCString { Darwin.write(AppLogger.crashLogFD, $0, strlen($0)) }
                var n = Int(sig)
                var digits: [CChar] = []
                if n == 0 { digits.append(CChar(48)) }
                while n > 0 { digits.insert(CChar(48 + (n % 10)), at: 0); n /= 10 }
                digits.append(CChar(10)) // \n
                digits.withUnsafeBufferPointer { buf in
                    _ = Darwin.write(AppLogger.crashLogFD, buf.baseAddress, buf.count)
                }
                fsync(AppLogger.crashLogFD)
                // Re-raise with default handler so the OS still records a
                // proper crash report.
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
}
