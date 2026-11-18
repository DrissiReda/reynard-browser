//
//  SceneDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import UIKit
import GeckoView

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var webAppLaunchPending = false
    private var isWebAppScene = false
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        AppleSSOListener.shared.register()
        
        let webAppPrefix = "sceneID:com.apple.webapp-"
        let browserViewController: BrowserViewController
        if session.persistentIdentifier.hasPrefix(webAppPrefix) {
            let clipID = String(session.persistentIdentifier.dropFirst(webAppPrefix.count))
            let launchURL = connectionOptions.urlContexts
                .compactMap { resolvedBrowserURL(from: $0.url) }
                .first { $0.scheme?.lowercased() == "https" }
            isWebAppScene = true
            // iOS may also (re)connect a web app window for an unrelated link: the window still
            // starts on its own page and the link goes to the browser.
            let startURL = WebApps.info(clipID).url ?? launchURL
            if let launchURL, let startURL, WebApps.normalize(launchURL) != WebApps.normalize(startURL) {
                DispatchQueue.main.async { self.forwardToBrowser(launchURL) }
            }
            browserViewController = BrowserViewController(webAppID: clipID, startURL: startURL)
        } else {
            browserViewController = BrowserViewController()
        }
        browserViewController.sessionManager.setApplicationForeground(scene.activationState != .background)
        
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = AppAppearanceController.userInterfaceStyle(for: Prefs.AppearanceSettings.appAppearance)
        window.rootViewController = browserViewController
        window.makeKeyAndVisible()
        self.window = window
        
        if !isWebAppScene {
            handleIncomingURLContexts(connectionOptions.urlContexts)
            // A link a web app window passed on (see forwardToBrowser).
            if let url = connectionOptions.userActivities.first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?.webpageURL {
                handleIncomingURL(url)
            }
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard !isWebAppScene, userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        handleIncomingURL(url)
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleIncomingURLContexts(URLContexts)
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {}
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        
        browserViewController.startScreenOrientationHandling()
        // One addon UI owner at a time: the window in front (browser or a web app).
        AddonRuntime.shared.delegate = browserViewController.addonCoordinator
        browserViewController.sessionManager.applicationDidBecomeActive()
        browserViewController.tabManager.applicationDidBecomeActive()
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        
        browserViewController.stopScreenOrientationHandling()
        browserViewController.sessionManager.applicationWillResignActive()
    }
    
    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        (window?.rootViewController as? BrowserViewController)?
            .screenOrientationChanged(to: windowScene.interfaceOrientation)
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        let browserViewController = window?.rootViewController as? BrowserViewController
        browserViewController?.sessionManager.setApplicationForeground(true)
        // Opened from Reynard's own icon: back to the browser. A web clip
        // launch re-enters web app mode in scene(_:openURLContexts:).
        if !webAppLaunchPending && !isWebAppScene {
            browserViewController?.isStandalone = false
        }
        webAppLaunchPending = false
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? BrowserViewController)?
            .sessionManager.setApplicationForeground(false)
    }
    
    private func handleIncomingURLContexts(_ urlContexts: Set<UIOpenURLContext>) {
        guard let incomingURL = urlContexts.first?.url else {
            return
        }
        if isWebAppScene {
            guard let url = resolvedBrowserURL(from: incomingURL),
                  let bvc = window?.rootViewController as? BrowserViewController else { return }
            // iOS hands a link to the last active Reynard window, which may be a web app.
            // Only the web app's own launch stays here; anything else goes to the browser.
            if bvc.webAppOwns(url) {
                bvc.loadInWebApp(url)
            } else {
                forwardToBrowser(url)
            }
            return
        }
        handleIncomingURL(incomingURL)
    }
    
    private func handleIncomingURL(_ incomingURL: URL) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController,
              let resolvedURL = resolvedBrowserURL(from: incomingURL) else {
            return
        }
        
        let isWebApp = WebApps.contains(resolvedURL)
        webAppLaunchPending = isWebApp
        DispatchQueue.main.async {
            browserViewController.loadViewIfNeeded()
            browserViewController.sidebarCoordinator.loadContentIfNeeded()
            if isWebApp {
                browserViewController.openWebApp(resolvedURL)
            } else {
                browserViewController.sidebarCoordinator.openExternalURL(resolvedURL)
            }
        }
    }
    
    /// Opens a link in the browser window, creating one when only web app windows are open.
    /// iPhone cannot activate another scene (UISceneErrorDomain 0, "does not support multiple
    /// scenes"): there Redval Tweaks routes outside links to the browser window in SpringBoard. A
    /// link that still reaches a web app window loads in it rather than being dropped.
    private func forwardToBrowser(_ url: URL) {
        let browserSession = UIApplication.shared.openSessions.first {
            !$0.persistentIdentifier.hasPrefix("sceneID:com.apple.webapp-") && $0.role == .windowApplication
        }
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        UIApplication.shared.requestSceneSessionActivation(browserSession, userActivity: activity, options: nil) { [weak self] _ in
            DispatchQueue.main.async {
                (self?.window?.rootViewController as? BrowserViewController)?.loadInWebApp(url)
            }
        }
    }

    private func resolvedBrowserURL(from incomingURL: URL) -> URL? {
        guard let scheme = incomingURL.scheme?.lowercased() else {
            return nil
        }
        
        if scheme == "http" || scheme == "https" {
            return incomingURL
        }
        
        guard scheme == "reynard",
              let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
              let encodedURL = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        
        return URL(string: encodedURL)
    }
}
