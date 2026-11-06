//
//  BitwardenSettingsSection.swift
//  Reynard
//
//  Settings row to enroll the Bitwarden vault for Face ID unlock. Enrolling
//  logs into Bitwarden/vaultwarden once, derives the account's user key and
//  stores it behind Face ID; the master password is never saved. After that
//  the Bitwarden extension unlocks via Face ID (see BitwardenNativeHost).
//

import UIKit

final class BitwardenSettingsSection: NSObject {
    private enum Defaults {
        static let userIdKey = "bitwarden.faceid.userId"
        static let serverKey = "bitwarden.faceid.server"
        static let deviceIdKey = "bitwarden.faceid.deviceId"
        static let defaultServer = "https://warden.redval.ovh"
    }

    private let store = BiometricKeyStore()

    private var enrolledUserId: String? {
        UserDefaults.standard.string(forKey: Defaults.userIdKey)
    }

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: Defaults.deviceIdKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Defaults.deviceIdKey)
        return id
    }

    /// Hidden unless biometrics are available on the device.
    var isAvailable: Bool { BiometricKeyStore.isAvailable }

    var rowCount: Int { 1 }

    func cell(at index: Int) -> UITableViewCell {
        let cell = SettingsTableViewCell(style: .value1, reuseIdentifier: nil)
        if let id = enrolledUserId, store.has(account: id) {
            cell.textLabel?.text = NSLocalizedString("Bitwarden Face ID Unlock", comment: "")
            cell.detailTextLabel?.text = NSLocalizedString("Enabled", comment: "")
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = .none
        } else {
            cell.textLabel?.text = NSLocalizedString("Set Up Bitwarden Face ID Unlock", comment: "")
            cell.textLabel?.textColor = .systemBlue
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func selectRow(at index: Int, from viewController: UIViewController) {
        if let id = enrolledUserId, store.has(account: id) {
            presentRemove(id: id, from: viewController)
        } else {
            presentEnroll(from: viewController)
        }
    }

    func footerView() -> UIView? { nil }

    // MARK: - Enrollment

    private func presentEnroll(from vc: UIViewController) {
        let alert = UIAlertController(
            title: NSLocalizedString("Bitwarden Face ID Unlock", comment: ""),
            message: NSLocalizedString("Sign in once to enable Face ID. Your master password is not stored.", comment: ""),
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = "Server"; $0.text = UserDefaults.standard.string(forKey: Defaults.serverKey) ?? Defaults.defaultServer; $0.keyboardType = .URL; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addTextField { $0.placeholder = "Email"; $0.keyboardType = .emailAddress; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addTextField { $0.placeholder = "Master password"; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Enable", comment: ""), style: .default) { [weak self, weak vc] _ in
            guard let self, let vc else { return }
            let server = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let email = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let password = alert.textFields?[2].text ?? ""
            self.enroll(server: server, email: email, password: password, from: vc)
        })
        vc.present(alert, animated: true)
    }

    private func enroll(server: String, email: String, password: String, from vc: UIViewController) {
        guard let url = URL(string: server), !email.isEmpty, !password.isEmpty else {
            showResult(ok: false, message: NSLocalizedString("Enter server, email and master password.", comment: ""), from: vc)
            return
        }
        let client = BitwardenAuthClient(baseURL: url)
        let store = self.store
        let deviceId = self.deviceId
        Task { @MainActor in
            do {
                let enrolled = try await client.enroll(email: email, password: password, deviceId: deviceId)
                try store.store(enrolled.userKey, account: enrolled.userId)
                UserDefaults.standard.set(enrolled.userId, forKey: Defaults.userIdKey)
                UserDefaults.standard.set(server, forKey: Defaults.serverKey)
                self.showResult(ok: true, message: NSLocalizedString("Face ID unlock is on. Open Bitwarden and turn on \u{201C}Unlock with biometrics\u{201D}.", comment: ""), from: vc)
            } catch {
                self.showResult(ok: false, message: Self.describe(error), from: vc)
            }
        }
    }

    private func presentRemove(id: String, from vc: UIViewController) {
        let alert = UIAlertController(
            title: NSLocalizedString("Turn Off Face ID Unlock?", comment: ""),
            message: NSLocalizedString("Bitwarden will ask for your master password again.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Turn Off", comment: ""), style: .destructive) { [weak self, weak vc] _ in
            try? self?.store.delete(account: id)
            UserDefaults.standard.removeObject(forKey: Defaults.userIdKey)
            if let vc = vc as? SettingsViewController { vc.tableView.reloadData() }
        })
        vc.present(alert, animated: true)
    }

    private func showResult(ok: Bool, message: String, from vc: UIViewController) {
        let alert = UIAlertController(
            title: ok ? NSLocalizedString("Done", comment: "") : NSLocalizedString("Couldn\u{2019}t Enable", comment: ""),
            message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
            if let vc = vc as? SettingsViewController { vc.tableView.reloadData() }
        })
        vc.present(alert, animated: true)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case BitwardenAuthError.server(let code, _):
            return code == 400 ? NSLocalizedString("Wrong email or master password.", comment: "") : "Server error \(code)."
        case BitwardenAuthError.unsupportedKdf:
            return NSLocalizedString("This account uses an unsupported key type.", comment: "")
        case BitwardenAuthError.network(let m):
            return m
        default:
            return NSLocalizedString("Could not sign in.", comment: "")
        }
    }
}
