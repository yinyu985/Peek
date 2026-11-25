import Foundation
import Darwin
import os

// Only product events, never global keystrokes or window/document titles.
final class DiagnosticLog {
    static let shared = DiagnosticLog()
    private let queue = DispatchQueue(label:"Peek.Diagnostics",qos:.utility)
    private let directory: URL
    private let session = UUID().uuidString
    private let clock = ISO8601DateFormatter()
    private var day = "", part = 0, sequence: UInt64 = 0
    private let fallback = Logger(subsystem:"dev.local.Peek",category:"diagnostics")
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Peek")) {
        self.directory = directory; clock.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
    }
    private func rotate(_ date: Date,_ today: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let cutoff = String(clock.string(from:date.addingTimeInterval(-6*86400)).prefix(10))
        for url in try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey]) {
            let name = url.lastPathComponent
            if name.range(of:#"^peek-\d{4}-\d{2}-\d{2}(\.\d+)?\.jsonl$"#,options:.regularExpression) != nil {
                if String(name.dropFirst(5).prefix(10)) < cutoff { removeExpired(url) }
            } else if name == "app-launch.jsonl", let modified = try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate, modified < date.addingTimeInterval(-7*86400) { removeExpired(url) }
        }
        day = today; part = 0
    }
    private func removeExpired(_ url: URL) {
        do { try FileManager.default.removeItem(at:url) } catch { fallback.error("Could not remove expired diagnostic file: \(String(describing:error),privacy:.private)") }
    }
    private func append(_ data: Data) throws {
        while true {
            let suffix = part == 0 ? "":".\(part)"
            let fd = Darwin.open(directory.appendingPathComponent("peek-\(day)\(suffix).jsonl").path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0o600)
            guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }; defer { Darwin.close(fd) }
            var st = stat(); guard fstat(fd,&st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteUnknown) }
            if st.st_size >= 4*1024*1024 { part += 1; continue }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < data.count {
                    let n = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),data.count-offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }; offset += n
                }
            }
            return
        }
    }
    func record(_ event: String,_ fields: [String:Any]) {
        let date = Date()
        let trace = Thread.current.threadDictionary["Peek.request"] as? String, stage = Thread.current.threadDictionary["Peek.stage"] as? String
        queue.async {
            let stamp = self.clock.string(from:date), today = String(stamp.prefix(10))
            do {
                if today != self.day { try self.rotate(date,today) }
                self.sequence += 1
                var row = fields; if let stage { row["stage"] = stage }; if let trace { row["request"] = trace }; row["event"] = event; row["time"] = stamp; row["session"] = self.session; row["seq"] = self.sequence
                var data = try JSONSerialization.data(withJSONObject:row,options:.sortedKeys); data.append(10); try self.append(data)
            } catch { self.fallback.error("JSONL write failed: event=\(event,privacy:.public) error=\(String(describing:error),privacy:.private)") }
        }
    }
    func flush() { queue.sync {} }
}
