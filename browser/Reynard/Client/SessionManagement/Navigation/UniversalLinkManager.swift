//
//  UniversalLinkManager.swift
//  Reynard
//
//  Created by Minh Ton on 12/8/26.
//

import Foundation
import GeckoView
import UIKit

final class UniversalLinkManager {
    private struct HandoffKey: Hashable {
        let session: ObjectIdentifier
        let uri: String
    }
    
    private nonisolated final class OpenGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?
        
        func wait() async -> Bool {
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
        
        func finish(with result: Bool) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
    
    private var handoffTasks: [HandoffKey: Task<Bool, Never>] = [:]
    private var failedHandoffs = Set<HandoffKey>()
    // A navigation that started from a tap or an incoming link. Its redirects (HTTP or meta refresh)
    // may open an app for 10 s, but never one for the site the chain started on: that app sent the link.
    private struct HandoffChain {
        let originDomain: String
        let start: Date
        var isActive: Bool { Date().timeIntervalSince(start) < 10 }
    }
    private var chains: [ObjectIdentifier: HandoffChain] = [:]
    // Loop guard: last time Reynard opened an app for a web link.
    private var lastHandoff: Date?
    
    func decideHandoff(
        for request: LoadRequest,
        in session: GeckoSession
    ) async -> AllowOrDeny {
        guard
            Prefs.BrowsingSettings.openLinksInExternalApps,
            let url = URL(string: request.uri)
        else {
            return .allow
        }
        
        guard URLUtils.isWebURL(url) else {
            guard await confirmOpen() else {
                return .deny
            }
            return await open(url, universalLinksOnly: false) ? .deny : .allow
        }
        
        guard !session.isPrivateMode else {
            return .allow
        }
        
        // Custom schemes (tel:, mailto:, ...) and Apple Maps open any app, not just universal links.
        let internalSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "moz-extension", "resource", "chrome", "view-source", "reynard"]
        let scheme = url.scheme?.lowercased() ?? ""
        let isCustomLink = !internalSchemes.contains(scheme)
            || (scheme == "https" && url.host == "maps.apple.com")
        if isCustomLink {
            guard request.hasUserGesture || request.isUserInitiatedNavigation else {
                return .allow
            }
        } else {
            guard URLUtils.isWebURL(url), let destinationHost = url.host else {
                return .allow
            }
            let sessionID = ObjectIdentifier(session)
            if request.isUserInitiatedNavigation && !request.isRedirect {
                let originHost = request.triggerUri.flatMap { URL(string: $0)?.host } ?? destinationHost
                chains[sessionID] = HandoffChain(originDomain: Self.baseDomain(originHost), start: Date())
            }
            guard let chain = chains[sessionID], chain.isActive else {
                return .allow
            }
            let destinationDomain = Self.baseDomain(destinationHost)
            if destinationDomain == chain.originDomain {
                return .allow
            }
        }
        
        if !isCustomLink, let triggerUri = request.triggerUri,
           let triggerURL = URL(string: triggerUri),
           let triggerHost = triggerURL.host,
           let destinationHost = url.host,
           triggerHost.caseInsensitiveCompare(destinationHost) == .orderedSame {
            return .allow
        }
        
        let key = HandoffKey(session: ObjectIdentifier(session), uri: request.uri)
        if failedHandoffs.contains(key) {
            return .allow
        }
        if let task = handoffTasks[key] {
            return await task.value ? .deny : .allow
        }
        
        let task = Task { @MainActor in
            return await open(url, universalLinksOnly: !isCustomLink)
        }
        handoffTasks[key] = task
        defer { handoffTasks.removeValue(forKey: key) }
        
        let didOpen = await task.value
        if didOpen {
            failedHandoffs.remove(key)
            if !isCustomLink {
                lastHandoff = Date()
                chains.removeValue(forKey: ObjectIdentifier(session))
            }
        } else {
            failedHandoffs.insert(key)
        }
        return didOpen ? .deny : .allow
    }
    
    /// A link from another app: iOS already chose not to open an app for it, so only its redirects
    /// to another site may. Skipped right after Reynard opened an app, which may be bouncing back.
    func allowRedirectHandoff(in session: GeckoSession, from url: URL) {
        guard let host = url.host,
              lastHandoff.map({ Date().timeIntervalSince($0) >= 10 }) ?? true else {
            return
        }
        chains[ObjectIdentifier(session)] = HandoffChain(originDomain: Self.baseDomain(host), start: Date())
    }
    
    /// "shop.amazon.co.uk" -> "amazon.co.uk", "www.dealabs.com" -> "dealabs.com".
    static func baseDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<Substring> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or"]
        let keep = secondLevel.contains(labels[labels.count - 2]) && labels[labels.count - 1].count == 2 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
    
    func didCommitNavigation(in session: GeckoSession) {
        let sessionID = ObjectIdentifier(session)
        failedHandoffs = Set(failedHandoffs.filter { $0.session != sessionID })
    }
    
    func didCreateNewSession(from session: GeckoSession, for uri: String) {
        failedHandoffs.remove(
            HandoffKey(session: ObjectIdentifier(session), uri: uri)
        )
    }
    
    @MainActor
    private func confirmOpen() async -> Bool {
        return await withCheckedContinuation { continuation in
            AlertPresenter.show(
                title: NSLocalizedString("Open this page in another app?", comment: ""),
                message: nil,
                buttons: [
                    AlertPresenter.Button(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) {
                        continuation.resume(returning: false)
                    },
                    AlertPresenter.Button(title: NSLocalizedString("Open", comment: "")) {
                        continuation.resume(returning: true)
                    },
                ]
            )
        }
    }
    
    @MainActor
    private func open(_ url: URL, universalLinksOnly: Bool) async -> Bool {
        let gate = OpenGate()
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                gate.finish(with: false)
            } catch {}
        }
        defer { timeoutTask.cancel() }
        
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else {
                return false
            }
            UIApplication.shared.open(
                url,
                options: universalLinksOnly ? [.universalLinksOnly: true] : [:],
                completionHandler: { success in
                    gate.finish(with: success)
                }
            )
            return await gate.wait()
        }, onCancel: {
            gate.finish(with: false)
        })
    }
}
