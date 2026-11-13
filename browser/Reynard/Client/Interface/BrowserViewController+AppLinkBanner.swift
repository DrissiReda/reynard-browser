//
//  BrowserViewController+AppLinkBanner.swift
//  Reynard
//
//  Safari-style "Open in the app" banner for pages an installed app claims as universal links.
//

import UIKit

final class AppLinkBanner: UIVisualEffectView {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = UILabel()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isHidden = true
        alpha = 0

        let icon = UIImageView(image: UIImage(systemName: "arrow.up.forward.app.fill"))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail

        let openButton = UIButton(type: .system)
        openButton.setTitle(NSLocalizedString("Open", comment: ""), for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline).withBold()
        openButton.setTitleColor(.white, for: .normal)
        openButton.backgroundColor = .systemBlue
        openButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        openButton.layer.cornerRadius = 15
        openButton.layer.cornerCurve = .continuous
        openButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "")
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, openButton, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center
        stack.spacing = 10
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @objc private func openTapped() { onOpen?() }
    @objc private func closeTapped() { onClose?() }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(appName: String) {
        titleLabel.text = String(format: NSLocalizedString("Open in the “%@” app", comment: ""), appName)
        guard isHidden else { return }
        isHidden = false
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        transform = reduceMotion ? .identity : CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func hide() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = 0
        } completion: { finished in
            if finished && self.alpha == 0 { self.isHidden = true }
        }
    }
}

extension BrowserViewController {
    func configureAppLinkBanner() {
        view.insertSubview(appLinkBanner, belowSubview: tabOverview)
        NSLayoutConstraint.activate([
            appLinkBanner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            appLinkBanner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            appLinkBanner.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            appLinkBanner.topAnchor.constraint(greaterThanOrEqualTo: browserChrome.topToolbarBottomAnchor, constant: 8),
            appLinkBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8).withPriority(.defaultLow),
        ])
        appLinkBanner.onOpen = { [weak self] in
            guard let self, let url = self.appLinkBannerURL.flatMap(URL.init(string:)) else { return }
            self.appLinkBanner.hide()
            UIApplication.shared.open(url, options: [.universalLinksOnly: true])
        }
        appLinkBanner.onClose = { [weak self] in
            guard let self else { return }
            if let host = self.appLinkBannerURL.flatMap(URL.init(string:))?.host {
                self.appLinkBannerDismissedHosts.insert(host)
            }
            self.appLinkBanner.hide()
        }
    }

    /// Called with every address bar refresh; looks the page up once per URL.
    func refreshAppLinkBanner() {
        let urlString = tabManager.selectedTab?.url
        guard urlString != appLinkBannerURL else { return }
        appLinkBannerURL = urlString
        appLinkBanner.hide()
        guard webAppID == nil, let urlString, let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host, !appLinkBannerDismissedHosts.contains(host) else {
            return
        }
        appLinkTargetName(url) { [weak self] name in
            guard let self, let name, self.appLinkBannerURL == urlString else { return }
            self.appLinkBanner.show(appName: name)
        }
    }
}

private extension UIFont {
    func withBold() -> UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
