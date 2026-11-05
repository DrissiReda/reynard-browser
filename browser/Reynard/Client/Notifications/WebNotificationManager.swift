//
//  WebNotificationManager.swift
//  Reynard
//

import GeckoView
import UIKit
import UserNotifications

/// Shows web notifications (Notification API, service worker push) as iOS
/// notifications and routes taps back to Gecko.
final class WebNotificationManager: NSObject {
    static let shared = WebNotificationManager()

    weak var browserViewController: BrowserViewController?
    private var childPIDs = Set<pid_t>()
    private var keptAlivePIDs = Set<pid_t>()
    private var isKeepingAlive = false

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .geckoRuntimeChildProcessDidStart, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let pid = (notification.userInfo?["pid"] as? NSNumber)?.int32Value else { return }
            self.childPIDs.insert(pid)
            if self.isKeepingAlive { self.keepAlive(pid: pid) }
        }
        UNUserNotificationCenter.current().delegate = self
        GeckoWebNotifications.shared.delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async { self.startKeepAlive() }
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            await MainActor.run { startKeepAlive() }
        }
        return granted
    }

    // MARK: - Background keep-alive

    /// Keeps Reynard and its Gecko child processes (the socket process holds the
    /// push WebSocket) running in the background. Needs TrollStore entitlements.
    @MainActor
    private func startKeepAlive() {
        guard !isKeepingAlive else { return }
        isKeepingAlive = true
        keepAlive(pid: getpid())
        childPIDs.forEach(keepAlive(pid:))
    }

    private func keepAlive(pid: pid_t) {
        guard keptAlivePIDs.insert(pid).inserted else { return }
        NSLog("Reynard: keep-alive pid %d: %@", pid, BackgroundKeepAlive.acquire(forPID: pid))
    }
}

extension WebNotificationManager: GeckoWebNotificationDelegate {
    func show(_ notification: GeckoWebNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.text
        content.subtitle = notification.source ?? URL(string: notification.origin)?.host ?? ""
        content.threadIdentifier = notification.origin
        if !notification.silent {
            content.sound = .default
        }
        content.userInfo = ["name": notification.name, "id": notification.id, "origin": notification.origin]
        // ponytail: no icon attachment; iOS shows the app icon. Download imageURL to a file if wanted.
        let request = UNNotificationRequest(identifier: notification.name, content: content, trigger: nil)
        Task {
            // The site permission can exist without iOS authorization (e.g. granted
            // before this feature existed); asking again is a no-op once decided.
            guard await requestAuthorization() else {
                NSLog("Reynard: web notification dropped, iOS notifications not authorized")
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                NSLog("Reynard: web notification failed: %@", error.localizedDescription)
            }
        }
    }

    func close(name: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [name])
    }

    func openWindow(url: String, windowId: String) -> Bool {
        guard let browserViewController else { return false }
        return browserViewController.tabManager.createRegularTab(
            selecting: true, windowId: windowId, url: url
        ) != nil
    }
}

extension WebNotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let name = info["name"] as? String,
           let id = info["id"] as? String,
           let origin = info["origin"] as? String {
            GeckoWebNotifications.shared.click(name: name, id: id, origin: origin)
        }
        completionHandler()
    }
}
