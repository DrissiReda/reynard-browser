//
//  BrowserViewController+WebApp.swift
//  Reynard
//

import Network
import UIKit

// Web apps: "Add to Home Screen" installs a configuration profile with a web
// clip that opens reynard://app?url=…, which shows the site without browser
// chrome (see isStandalone).

extension BrowserViewController {
    /// Opens a web app launched from its home screen web clip.
    func openWebApp(_ url: URL) {
        let host = url.host
        if let index = tabManager.regularTabs.firstIndex(where: { $0.url.flatMap(URL.init(string:))?.host == host }) {
            tabManager.selectTab(at: index, mode: .regular)
        } else {
            sidebarCoordinator.openExternalURL(url)
        }
        isStandalone = true
    }

    func addToHomeScreen(tab: Tab, url: URL) {
        let manifest = tab.webAppManifest ?? [:]
        let name = (manifest["short_name"] as? String) ?? (manifest["name"] as? String) ?? tab.title
        let startURL = (manifest["start_url"] as? String).flatMap(URL.init(string:)) ?? url

        let alert = UIAlertController(
            title: NSLocalizedString("Add to Home Screen", comment: ""),
            message: NSLocalizedString("Settings will ask you to install a profile that adds this icon. It opens the site without browser controls.", comment: ""),
            preferredStyle: .alert
        )
        alert.addTextField { $0.text = name; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Add", comment: ""), style: .default) { _ in
            let label = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces)
            let profile = WebClipProfile.make(
                label: (label?.isEmpty == false ? label : nil) ?? name,
                startURL: startURL,
                icon: tab.favicon
            )
            WebClipProfileServer.shared.serve(profile)
        })
        present(alert, animated: true)
    }
}

enum WebClipProfile {
    static func make(label: String, startURL: URL, icon: UIImage?) -> Data {
        var components = URLComponents()
        components.scheme = "reynard"
        components.host = "app"
        components.queryItems = [URLQueryItem(name: "url", value: startURL.absoluteString)]
        let clipURL = components.url?.absoluteString ?? "reynard://"
        let host = startURL.host ?? "site"

        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.minh-ton.Reynard.webclip.\(host)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": label,
            "Label": label,
            "URL": clipURL,
            "IsRemovable": true,
            "FullScreen": false,
            "Precomposed": true,
            // iOS 14+: open the clip in Reynard directly instead of bouncing through Safari.
            "TargetApplicationBundleIdentifier": Bundle.main.bundleIdentifier ?? "com.minh-ton.Reynard",
        ]
        if let png = icon.flatMap(squareIcon)?.pngData() {
            clip["Icon"] = png
        }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            // Same identifier per site, so adding it again replaces the old one.
            "PayloadIdentifier": "com.minh-ton.Reynard.webapp.\(host)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "\(label) (Reynard)",
            "PayloadDescription": "Adds \(label) to the Home Screen. It opens in Reynard.",
            "PayloadOrganization": "Reynard",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
    }

    /// Home screen icons need an opaque square image.
    private static func squareIcon(_ image: UIImage) -> UIImage {
        let side: CGFloat = 180
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

/// iOS only installs profiles downloaded by Safari, so serve the profile on
/// localhost and open it there.
final class WebClipProfileServer {
    static let shared = WebClipProfileServer()
    private var listener: NWListener?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func serve(_ profile: Data) {
        stop()
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return }
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                var response = Data((
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/x-apple-aspen-config\r\n" +
                    "Content-Disposition: attachment; filename=\"webapp.mobileconfig\"\r\n" +
                    "Content-Length: \(profile.count)\r\n" +
                    "Connection: close\r\n\r\n"
                ).utf8)
                response.append(profile)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = listener.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(port)/webapp.mobileconfig") else { return }
            self?.backgroundTask = UIApplication.shared.beginBackgroundTask { self?.stop() }
            UIApplication.shared.open(url)
            // ponytail: fixed 60s window to let Safari fetch; plenty for one request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if self?.listener === listener { self?.stop() }
            }
        }
        listener.start(queue: .main)
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

@MainActor
final class AddToHomeScreenActivity: UIActivity {
    static let identifier = UIActivity.ActivityType("com.minh-ton.Reynard.AddToHomeScreenActivity")
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { Self.identifier }
    override var activityTitle: String? { NSLocalizedString("Add to Home Screen", comment: "") }
    override var activityImage: UIImage? { UIImage(systemName: "plus.app") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        return url.scheme == "https" || url.scheme == "http"
    }

    override func perform() {
        activityDidFinish(true)
    }
}
