//
//  BitwardenLogViewController.swift
//  Reynard
//
//  Read-only dump of BitwardenLog for diagnosing Face ID unlock on-device.
//

import UIKit

final class BitwardenLogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bitwarden Logs"
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload)),
            UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyAll)),
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearAll)),
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() { textView.text = BitwardenLog.dump() }
    @objc private func copyAll() { UIPasteboard.general.string = BitwardenLog.dump() }
    @objc private func clearAll() { BitwardenLog.clear(); reload() }
}
