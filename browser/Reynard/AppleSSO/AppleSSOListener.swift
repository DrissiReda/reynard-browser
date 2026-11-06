//
//  AppleSSOListener.swift
//  Reynard
//
//  Gecko holds an appleid.apple.com/auth/authorize page load and asks here
//  ("Reynard:SOAuthorize", sent from GeckoViewStartup). AppleSSOBridge shows
//  Apple's native sheet; the reply tells Gecko what response to serve instead.
//

import UIKit
import GeckoView

extension Notification.Name { static let appleSSOFinished = Notification.Name("appleSSOFinished") }

@MainActor
final class AppleSSOListener: GeckoEventListenerInternal {
    static let shared = AppleSSOListener()
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true
        GeckoEventDispatcherWrapper.runtimeInstance.addListener(type: "Reynard:SOAuthorize", listener: self)
    }

    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        guard let spec = message?["url"] as? String, let url = URL(string: spec) else {
            return ["handled": false]
        }
        let headers = (message?["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let origin = message?["origin"] as? String
        let userGesture = message?["userGesture"] as? Bool ?? false
        let popup = message?["popup"] as? Bool ?? false
        let presenter = UIApplication.shared.topViewController()

        return await withCheckedContinuation { continuation in
            AppleSSOBridge.authorizeURL(
                url, headers: headers, initiatorOrigin: origin, userGesture: userGesture,
                popup: popup, presenter: presenter
            ) { status, headers, cookies, body, handled in
                if popup {
                    NotificationCenter.default.post(name: .appleSSOFinished, object: nil, userInfo: ["handled": handled])
                }
                continuation.resume(returning: [
                    "handled": handled,
                    "status": status,
                    "headers": headers,
                    "cookies": cookies,
                    "body": body.base64EncodedString(),
                ] as [String: Any])
            }
        }
    }
}
