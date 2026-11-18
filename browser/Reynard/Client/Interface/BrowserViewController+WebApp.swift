//
//  BrowserViewController+WebApp.swift
//  Reynard
//

import UIKit
import Darwin

// Web apps: "Add to Home Screen" writes a web clip the way Safari does (private
// UIWebClip + SpringBoard's addWebClipToHomeScreen, entitlement in
// Reynard.private.entitlements). The clip holds the plain site URL and names
// Reynard as its app, so tapping it opens the site here without browser chrome
// (see isStandalone). WebApps remembers the start URL to tell such a launch
// from an ordinary link.

extension BrowserViewController {
    /// Opens a web app launched from its home screen web clip.
    func openWebApp(_ url: URL) {
        if let id = webAppTabIDs[url.absoluteString],
           let index = tabManager.regularTabs.firstIndex(where: { $0.id == id }) {
            tabManager.selectTab(at: index, mode: .regular)
        } else {
            webAppTabIDs[url.absoluteString] = tabManager.openExternalURL(url)?.id
        }
        isStandalone = true
    }

    /// Whether a link opened from outside belongs to this web app window (same site as its start URL).
    func webAppOwns(_ url: URL) -> Bool {
        guard let host = webAppStartURL?.host?.lowercased() else { return false }
        return url.host?.lowercased() == host
    }

    /// Standalone web app: its single tab, recreated if ever closed.
    func startWebApp() {
        let index = tabManager.addTab(selecting: true)
        if let url = webAppStartURL {
            tabManager.browse(to: url.absoluteString, in: tabManager.regularTabs[index])
        }
    }

    func loadInWebApp(_ url: URL) {
        loadViewIfNeeded()
        guard let tab = tabManager.selectedTab else { return startWebApp() }
        tabManager.browse(to: url.absoluteString, in: tab)
    }

    private var webAppInfo: WebApps.Info { WebApps.info(webAppID ?? "") }

    var webAppStatusBarStyle: UIStatusBarStyle {
        let color = UIColor(cssHex: webAppInfo.theme) ?? UIColor(cssHex: webAppInfo.background)
        guard let color else { return .default }
        return color.isDarkCSS ? .lightContent : .darkContent
    }

    /// Safari-like launch screen, removed on first page load (or after 8 s).
    func installWebAppSplash() {
        let info = webAppInfo
        view.backgroundColor = UIColor(cssHex: info.theme) ?? .systemBackground
        let splash = UIView(frame: view.bounds)
        splash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        splash.backgroundColor = UIColor(cssHex: info.background) ?? .systemBackground
        let icon = UIImageView(image: WebClip.icon(for: webAppID ?? ""))
        icon.contentMode = .scaleAspectFill
        icon.layer.cornerRadius = 27
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        let label = UILabel()
        label.text = info.name
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = (UIColor(cssHex: info.background)?.isDarkCSS ?? false) ? .white : .black
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        splash.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 120),
            icon.heightAnchor.constraint(equalToConstant: 120),
            stack.centerXAnchor.constraint(equalTo: splash.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: splash.centerYAnchor),
        ])
        view.addSubview(splash)
        webAppSplash = splash
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.dismissWebAppSplash() }
    }

    func dismissWebAppSplash() {
        guard let splash = webAppSplash else { return }
        webAppSplash = nil
        UIView.animate(withDuration: 0.25, animations: { splash.alpha = 0 }) { _ in splash.removeFromSuperview() }
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
            let typed = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces)
            let label = (typed?.isEmpty == false ? typed : nil) ?? name
            WebApps.add(startURL)
            // The tab often has no icon loaded yet: fetch the site's largest (manifest or
            // apple-touch-icon) first, else the clip shows a blank tile.
            Task { @MainActor in
                let fetched = await FaviconStore.shared.favicon(for: url, webAppManifest: manifest)
                let icon = fetched ?? tab.favicon ?? WebClip.letterIcon(label)
                if let clipID = WebClip.install(label: label, startURL: startURL, icon: icon) {
                    WebApps.setInfo(clipID, WebApps.Info(
                        url: startURL, name: label,
                        background: manifest["background_color"] as? String,
                        theme: manifest["theme_color"] as? String))
                } else {
                    let fail = UIAlertController(title: NSLocalizedString("Could not add the icon", comment: ""), message: nil, preferredStyle: .alert)
                    fail.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(fail, animated: true)
                }
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

    struct Info {
        var url: URL?
        var name: String
        var background: String?
        var theme: String?
    }
    private static let infoKey = "webAppInfo"
    static func setInfo(_ id: String, _ info: Info) {
        var all = UserDefaults.standard.dictionary(forKey: infoKey) as? [String: [String: String]] ?? [:]
        all[id] = ["url": info.url?.absoluteString ?? "", "name": info.name,
                   "background": info.background ?? "", "theme": info.theme ?? ""]
        UserDefaults.standard.set(all, forKey: infoKey)
    }
    static func info(_ id: String) -> Info {
        let d = (UserDefaults.standard.dictionary(forKey: infoKey) as? [String: [String: String]])?[id] ?? [:]
        return Info(url: d["url"].flatMap(URL.init(string:)), name: d["name"] ?? "",
                    background: d["background"], theme: d["theme"])
    }
    private static func normalize(_ url: URL) -> String {
        var s = url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum WebClip {
    /// Writes ~/Library/WebClips/<id>.webclip (UIWebClip createOnDisk) and asks
    /// SpringBoard to show it. Returns the clip id, nil when UIKit refused to write it.
    static func install(label: String, startURL: URL, icon: UIImage?) -> String? {
        // SpringBoard rejects (KERN_INVALID_ARGUMENT) any identifier that is not 32 hex characters.
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let cls = NSClassFromString("UIWebClip") as? NSObject.Type,
              let clip = cls.perform(NSSelectorFromString("webClipWithIdentifier:"), with: identifier)?
                .takeUnretainedValue() as? NSObject else { return nil }
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
        guard let imp = clip.method(for: create), unsafeBitCast(imp, to: BoolCall.self)(clip, create) else { return nil }
        // SpringBoard reads the clip from /var/mobile/Library/WebClips. If UIKit wrote it into the
        // app container instead, copy it there (the app runs without a sandbox).
        let path = (cls.perform(NSSelectorFromString("pathForWebClipWithIdentifier:"), with: identifier)?
            .takeUnretainedValue() as? String) ?? ""
        let shared = "/var/mobile/Library/WebClips/\(identifier).webclip"
        let fm = FileManager.default
        if path != shared, fm.fileExists(atPath: path), !fm.fileExists(atPath: shared) {
            try? fm.createDirectory(atPath: "/var/mobile/Library/WebClips", withIntermediateDirectories: true)
            try? fm.copyItem(atPath: path, toPath: shared)
        }
        // Same call UIApplication.addWebClipToHomeScreen: makes, which drops the result.
        if let h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW),
           let port = dlsym(h, "SBSSpringBoardServerPort"), let add = dlsym(h, "SBAddWebClipToHomeScreen") {
            typealias Port = @convention(c) () -> mach_port_t
            typealias Add = @convention(c) (mach_port_t, UnsafePointer<CChar>) -> kern_return_t
            _ = identifier.withCString { unsafeBitCast(add, to: Add.self)(unsafeBitCast(port, to: Port.self)(), $0) }
        }
        return identifier
    }

    /// The clip's icon, read back from the private UIWebClip.
    static func icon(for identifier: String) -> UIImage? {
        guard let cls = NSClassFromString("UIWebClip") as? NSObject.Type,
              let clip = cls.perform(NSSelectorFromString("webClipWithIdentifier:"), with: identifier)?
                .takeUnretainedValue() as? NSObject else { return nil }
        return clip.value(forKey: "iconImage") as? UIImage
    }

    /// Fallback tile when the site has no usable icon: first letter on a gray square.
    static func letterIcon(_ label: String) -> UIImage {
        let side: CGFloat = 180
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor.systemGray.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            let text = String(label.prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 100, weight: .semibold), .foregroundColor: UIColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        }
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

extension UIColor {
    /// CSS #rgb / #rrggbb.
    convenience init?(cssHex: String?) {
        guard var h = cssHex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    var isDarkCSS: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: nil)
        return 0.299 * r + 0.587 * g + 0.114 * b < 0.5
    }
}
