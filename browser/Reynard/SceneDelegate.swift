//
//  SceneDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var webAppLaunchPending = false
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        AppleSSOListener.shared.register()
        
        let browserViewController = BrowserViewController()
        browserViewController.sessionManager.setApplicationForeground(scene.activationState != .background)
        
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = AppAppearanceController.userInterfaceStyle(for: Prefs.AppearanceSettings.appAppearance)
        window.rootViewController = browserViewController
        window.makeKeyAndVisible()
        self.window = window
        
        handleIncomingURLContexts(connectionOptions.urlContexts)
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
        if !webAppLaunchPending {
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
        handleIncomingURL(incomingURL)
    }
    
    private func handleIncomingURL(_ incomingURL: URL) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController,
              let resolvedURL = resolvedBrowserURL(from: incomingURL) else {
            return
        }
        
        let isWebApp = incomingURL.scheme?.lowercased() == "reynard" && incomingURL.host == "app"
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
