//
//  BrowserViewController+WebApp.swift
//  Reynard
//

import UIKit

// Web apps: "Add to Home Screen" writes a web clip the way Safari does (private
// UIWebClip + SpringBoard's addWebClipToHomeScreen, entitlement in
// Reynard.private.entitlements). The clip holds the plain site URL and names
// Reynard as its app, so tapping it opens the site here without browser chrome
// (see isStandalone). WebApps remembers the start URL to tell such a launch
// from an ordinary link.

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
            message: NSLocalizedString("The icon opens the site in Reynard without browser controls.", comment: ""),
            preferredStyle: .alert
        )
        alert.addTextField { $0.text = name; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Add", comment: ""), style: .default) { [weak self] _ in
            let label = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces)
            WebApps.add(startURL)
            let ok = WebClip.install(label: (label?.isEmpty == false ? label : nil) ?? name, startURL: startURL, icon: tab.favicon)
            if !ok {
                let fail = UIAlertController(title: NSLocalizedString("Could not add the icon", comment: ""), message: nil, preferredStyle: .alert)
                fail.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(fail, animated: true)
            }
        })
        present(alert, animated: true)
    }
}

/// Start URLs of installed web apps: a plain https clip URL opened from the
/// home screen is recognised by this list, no custom scheme needed.
enum WebApps {
    private static let key = "webAppStartURLs"
    static func add(_ url: URL) {
        let urls = Set((UserDefaults.standard.stringArray(forKey: key) ?? []) + [normalize(url)])
        UserDefaults.standard.set(Array(urls), forKey: key)
    }
    static func contains(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(normalize(url))
    }
    private static func normalize(_ url: URL) -> String {
        var s = url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum WebClip {
    /// Writes ~/Library/WebClips/<id>.webclip (UIWebClip createOnDisk) and asks
    /// SpringBoard to show it. Returns false when UIKit refused to write it.
    static func install(label: String, startURL: URL, icon: UIImage?) -> Bool {
        let identifier = UUID().uuidString
        guard let cls = NSClassFromString("UIWebClip") as? NSObject.Type,
              let clip = cls.perform(NSSelectorFromString("webClipWithIdentifier:"), with: identifier)?
                .takeUnretainedValue() as? NSObject else { return false }
        clip.setValue(startURL, forKey: "pageURL")
        clip.setValue(label, forKey: "title")
        clip.setValue(Bundle.main.bundleIdentifier, forKey: "applicationBundleIdentifier")
        if let icon = icon.map(squareIcon) {
            typealias SetIcon = @convention(c) (AnyObject, Selector, UIImage, Bool) -> Void
            let sel = NSSelectorFromString("setIconImage:isPrecomposed:")
            if let imp = clip.method(for: sel) { unsafeBitCast(imp, to: SetIcon.self)(clip, sel, icon, true) }
        }
        typealias BoolCall = @convention(c) (AnyObject, Selector) -> Bool
        let create = NSSelectorFromString("createOnDisk")
        guard let imp = clip.method(for: create), unsafeBitCast(imp, to: BoolCall.self)(clip, create) else { return false }
        // ponytail: SpringBoard logs but does not return an entitlement failure; without the
        // entitlement the icon shows after the next respring instead of right away.
        typealias AddCall = @convention(c) (AnyObject, Selector, NSString) -> Int32
        let add = NSSelectorFromString("addWebClipToHomeScreen:")
        if let imp = UIApplication.shared.method(for: add) { _ = unsafeBitCast(imp, to: AddCall.self)(UIApplication.shared, add, identifier as NSString) }
        return true
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
