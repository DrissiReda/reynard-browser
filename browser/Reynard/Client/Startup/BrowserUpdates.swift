//
//  BrowserUpdates.swift
//  Reynard
//
//  Created by Minh Ton on 21/4/26.
//

import Foundation

final class BrowserUpdates: NSObject {
    static let shared = BrowserUpdates()
    
    private(set) var hasUpdate: Bool = false
    private(set) var latestVersion: String = ""
    private(set) var sourceData: Data?
    var cachedReleaseNotes: NSAttributedString?
    
    // Redval builds are published to the "reynard releases" public share on cloud.redval.ovh.
    // UserDefaults "ReynardUpdateFeedURL" overrides it (the simulator smoke test points it at a test feed).
    private static let defaultSourceURL = "https://cloud.redval.ovh/public/api/resources/download?hash=x_HIVsLpIMmmqBWkOySahA&file=/source.json"
    private static var sourceURL: String {
        UserDefaults.standard.string(forKey: "ReynardUpdateFeedURL") ?? defaultSourceURL
    }
    private override init() {
        super.init()
        
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let sideloadIPA = docs.appendingPathComponent("Reynard.ipa")
        try? FileManager.default.removeItem(at: sideloadIPA)
        
        fetchUpdates()
    }
    
    private func fetchUpdates() {
        DispatchQueue.global(qos: .background).async {
            guard let url = URL(string: Self.sourceURL),
                  let data = try? Data(contentsOf: url) else { return }
            
            self.sourceData = data
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = json["apps"] as? [[String: Any]],
                  let firstApp = apps.first,
                  let versions = firstApp["versions"] as? [[String: Any]],
                  let latestEntry = versions.first,
                  let latestVersionStr = latestEntry["version"] as? String,
                  let latestDateStr = latestEntry["date"] as? String else { return }
            
            let currentVersionStr = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            
            let versionIsNewer = Self.isVersion(latestVersionStr, greaterThan: currentVersionStr)
            guard versionIsNewer else { return }
            
            let formatter = ISO8601DateFormatter()
            guard let latestDate = formatter.date(from: latestDateStr) else { return }
            
            if let currentEntry = versions.first(where: { ($0["version"] as? String) == currentVersionStr }),
               let currentDateStr = currentEntry["date"] as? String,
               let currentDate = formatter.date(from: currentDateStr) {
                guard currentDate < latestDate else { return }
            }
            
            DispatchQueue.main.async {
                self.hasUpdate = true
                self.latestVersion = latestVersionStr
                NotificationCenter.default.post(name: .appUpdateAvailable, object: nil)
            }
        }
    }
    
    /// "0.22.1-dev3" -> [0, 22, 1, 3]. A version without "-devN" is a release and sorts after every devN of the same base.
    static func versionParts(_ v: String) -> [Int] {
        let pieces = v.components(separatedBy: "-dev")
        var parts = pieces[0].split(separator: ".").compactMap { Int($0) }
        while parts.count < 3 { parts.append(0) }
        parts.append(pieces.count > 1 ? (Int(pieces[1]) ?? 0) : Int.max)
        return parts
    }

    static func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        let parts1 = versionParts(v1)
        let parts2 = versionParts(v2)
        for (p1, p2) in zip(parts1, parts2) where p1 != p2 {
            return p1 > p2
        }
        return false
    }
}
