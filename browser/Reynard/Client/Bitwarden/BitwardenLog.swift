//
//  BitwardenLog.swift
//  Reynard
//
//  Tiny in-memory ring buffer for Bitwarden Face ID diagnostics, surfaced in
//  Settings → Bitwarden → View Logs (device syslog isn't reachable on a stock
//  phone). Also mirrors to NSLog.
//

import Foundation

enum BitwardenLog {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let cap = 500
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func add(_ message: String) {
        let line = "\(fmt.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        lock.unlock()
        NSLog("[bitwarden] %@", message)
    }

    static func dump() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? "(no events yet)" : lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
    }
}
