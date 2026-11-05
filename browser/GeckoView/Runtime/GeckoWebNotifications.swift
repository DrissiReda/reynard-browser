//
//  GeckoWebNotifications.swift
//  Reynard
//

import Foundation

public struct GeckoWebNotification {
    public let name: String
    public let id: String
    public let title: String
    public let text: String
    public let imageURL: String?
    public let origin: String
    public let source: String?
    public let silent: Bool
    public let isPrivate: Bool
}

public protocol GeckoWebNotificationDelegate: AnyObject {
    @MainActor func show(_ notification: GeckoWebNotification)
    @MainActor func close(name: String)
    /// A service worker called clients.openWindow(url): open a tab whose session uses `windowId`.
    @MainActor func openWindow(url: String, windowId: String) -> Bool
}

/// Bridges Gecko's system alerts backend (GeckoViewAlerts.sys.mjs) and
/// service worker windows to the app.
public final class GeckoWebNotifications: NSObject, GeckoEventListenerInternal {
    public static let shared = GeckoWebNotifications()
    public weak var delegate: GeckoWebNotificationDelegate?

    private static let events = [
        "GeckoView:WebNotification:Show",
        "GeckoView:WebNotification:Close",
        "GeckoView:ServiceWorkerOpenWindow",
        "History:GetPrePathLastVisitedTimeMilliseconds",
    ]

    private override init() {
        super.init()
        for event in Self.events {
            GeckoEventDispatcherWrapper.runtimeInstance.addListener(type: event, listener: self)
        }
    }

    /// The user tapped a notification.
    public func click(name: String, id: String, origin: String) {
        GeckoEventDispatcherWrapper.runtimeInstance.dispatch(
            type: "GeckoView:WebNotification:Click",
            message: ["name": name, "id": id, "origin": origin]
        )
    }

    @MainActor
    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        switch type {
        case "GeckoView:WebNotification:Show":
            guard let name = message?["name"] as? String else { return nil }
            delegate?.show(GeckoWebNotification(
                name: name,
                id: message?["id"] as? String ?? name,
                title: message?["title"] as? String ?? "",
                text: message?["text"] as? String ?? "",
                imageURL: message?["imageURL"] as? String,
                origin: message?["origin"] as? String ?? "",
                source: message?["source"] as? String,
                silent: message?["silent"] as? Bool ?? false,
                isPrivate: message?["privateBrowsing"] as? Bool ?? false
            ))
        case "GeckoView:WebNotification:Close":
            if let name = message?["name"] as? String { delegate?.close(name: name) }
        case "GeckoView:ServiceWorkerOpenWindow":
            guard let url = message?["url"] as? String, let delegate else { return nil }
            let windowId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            guard delegate.openWindow(url: url, windowId: windowId) else { return nil }
            return ["sessionId": windowId, "isOpen": false]
        case "History:GetPrePathLastVisitedTimeMilliseconds":
            // PushService drops pushes for origins never visited. Reynard keeps no
            // per-origin visit index, so report a visit now.
            // ponytail: no push quota reset on history clear; query HistoryStore if needed.
            return Date().timeIntervalSince1970 * 1000
        default:
            break
        }
        return nil
    }
}
