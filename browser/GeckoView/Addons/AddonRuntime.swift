//
//  AddonRuntime.swift
//  Reynard
//
//  Created by Minh Ton on 28/4/26.
//

import Foundation

public final class AddonRuntime: NSObject, GeckoEventListenerInternal {
    public static let shared = AddonRuntime()
    
    public weak var delegate: AddonEmbedderDelegate? {
        didSet {
            if delegate == nil {
                attachedActionDelegateAddonIDs.removeAll()
            }
            guard delegate != nil else {
                return
            }
            Task { @MainActor in
                _ = try? await self.list()
                self.notifyActionDelegateAttached()
            }
        }
    }
    
    var addonsByID: [String: Addon] = [:]
    var attachedActionDelegateAddonIDs = Set<String>()
    var installCounter = 0

    // Native-messaging delegates for background-script ports. Background
    // scripts have no tab session, so connectNative dispatches on the runtime
    // dispatcher, not a per-session one. Keyed by extensionID + nativeApp.
    var runtimeMessageDelegates: [AddonMessageRegistrationKey: WeakAddonMessageDelegate] = [:]
    
    public var installedAddons: [Addon] {
        return Array(addonsByID.values).sorted {
            ($0.metaData.name ?? $0.id).localizedCaseInsensitiveCompare($1.metaData.name ?? $1.id) == .orderedAscending
        }
    }
    
    private override init() {
        super.init()
        for event in AddonRuntimeEvent.allCases {
            GeckoEventDispatcherWrapper.runtimeInstance.addListener(type: event.rawValue, listener: self)
        }
        for event in ["GeckoView:WebExtension:Connect", "GeckoView:WebExtension:Message"] {
            GeckoEventDispatcherWrapper.runtimeInstance.addListener(type: event, listener: self)
        }
    }

    func register(sessionListener: AddonSessionListener) {
        guard let session = sessionListener.session else {
            return
        }
        for event in sessionListener.events {
            session.dispatcher.addListener(type: event, listener: sessionListener)
        }
    }

    @MainActor
    public func setRuntimeAddonMessageDelegate(
        _ delegate: AddonMessageDelegate?,
        extensionID: String,
        nativeApp: String
    ) {
        let key = AddonMessageRegistrationKey(extensionID: extensionID, nativeApp: nativeApp)
        if let delegate {
            runtimeMessageDelegates[key] = WeakAddonMessageDelegate(delegate)
        } else {
            runtimeMessageDelegates.removeValue(forKey: key)
        }
    }

    @MainActor
    func handleRuntimeAddonMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        guard let extensionID = message?["extensionId"] as? String,
              let nativeApp = message?["nativeApp"] as? String else {
            throw GeckoHandlerError("Missing WebExtension message recipient")
        }
        let key = AddonMessageRegistrationKey(extensionID: extensionID, nativeApp: nativeApp)
        guard let delegate = runtimeMessageDelegates[key]?.value else {
            throw GeckoHandlerError("No runtime WebExtension message delegate for \(extensionID)/\(nativeApp)")
        }
        return try await dispatchAddonMessage(
            type: type,
            message: message,
            extensionID: extensionID,
            nativeApp: nativeApp,
            session: nil,
            delegate: delegate
        )
    }
}
