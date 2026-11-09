//
//  DevLog.swift
//  Reynard
//

import Foundation

/// Test builds only: sends one diagnostic line to the developer's relay so device-only
/// failures (SpringBoard calls) can be read without a cable. Remove once fixed.
enum DevLog {
    static func post(_ line: String) {
        NSLog("[devlog] %@", line)
        guard let url = URL(string: "https://docs.redval.ovh/otc/log") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        request.httpBody = "reynard \(version) \(line)".data(using: .utf8)
        URLSession.shared.dataTask(with: request).resume()
    }
}
