import Foundation
import os

/// Appends timestamped lines to Library/Logs/TrueCloud/truecloud.log and the system log.
/// On macOS the file is in ~/Library/Logs; on iOS it is inside the app's sandbox, so the
/// system log (public, subsystem "com.samyakjain.truecloud") is how to read it from a connected Mac.
enum Log {
    private static let system = Logger(subsystem: "com.samyakjain.truecloud", category: "app")

    static let fileURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = library.appendingPathComponent("Logs/TrueCloud")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("truecloud.log")
    }()

    private static let queue = DispatchQueue(label: "com.samyakjain.truecloud.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: .now)) \(message)\n"
        system.notice("\(message, privacy: .public)")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// The last `maxLines` lines of the log file, oldest first.
    static func recentLines(_ maxLines: Int = 600) -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            // Only the tail matters; skip the start of a big file.
            let tail = data.count > 400_000 ? data.suffix(400_000) : data
            let lines = String(decoding: tail, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            return lines.suffix(maxLines).map(String.init)
        }
    }

    /// Empties the log file.
    static func clear() {
        queue.sync { try? Data().write(to: fileURL) }
    }
}
