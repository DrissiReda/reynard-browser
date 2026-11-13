//
//  BrowserViewController+AppLinkBanner.swift
//  Reynard
//
//  Safari-style "Open in the app" banner for pages an installed app claims as universal links.
//  It sits edge to edge at the top of the page and pushes the page down, like Safari's.
//

import UIKit

final class AppLinkBanner: UIView {
    static let height: CGFloat = 64

    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let openButton = UIButton(type: .custom)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        addSubview(separator)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        iconView.contentMode = .scaleAspectFill
        iconView.layer.cornerRadius = 9
        iconView.layer.cornerCurve = .continuous
        iconView.layer.borderWidth = 1 / UIScreen.main.scale
        iconView.layer.borderColor = UIColor.separator.cgColor
        iconView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.text = NSLocalizedString("Open in the app", comment: "")
        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 1

        openButton.setTitle(NSLocalizedString("OPEN", comment: ""), for: .normal)
        openButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        openButton.setTitleColor(.systemBlue, for: .normal)
        openButton.backgroundColor = .tertiarySystemFill
        openButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        openButton.layer.cornerRadius = 15
        openButton.layer.cornerCurve = .continuous
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        openButton.addTarget(self, action: #selector(openPressed), for: [.touchDown, .touchDragEnter])
        openButton.addTarget(self, action: #selector(openReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [closeButton, iconView, labels, openButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .center
        row.spacing = 10
        row.setCustomSpacing(4, after: closeButton)
        addSubview(row)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            openButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(appName: String, icon: UIImage?) {
        titleLabel.text = appName
        iconView.image = icon
        iconView.isHidden = icon == nil
        accessibilityLabel = String(format: NSLocalizedString("Open in the “%@” app", comment: ""), appName)
    }

    @objc private func openTapped() { onOpen?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func openPressed() {
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.openButton.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        }
    }
    @objc private func openReleased() {
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.openButton.transform = .identity
        }
    }
}

extension BrowserViewController {
    func configureAppLinkBanner() {
        // The clip view grows from 0 to the banner height; the page below is pushed down with it.
        let clip = appLinkBannerClip
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.clipsToBounds = true
        clip.addSubview(appLinkBanner)
        view.insertSubview(clip, belowSubview: browserChrome)
        let height = clip.heightAnchor.constraint(equalToConstant: 0)
        appLinkBannerHeight = height
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clip.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
            clip.topAnchor.constraint(greaterThanOrEqualTo: browserChrome.topToolbarBottomAnchor),
            clip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).withPriority(.defaultLow),
            height,
            appLinkBanner.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            appLinkBanner.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            appLinkBanner.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            contentView.topAnchor.constraint(greaterThanOrEqualTo: clip.bottomAnchor),
        ])
        appLinkBanner.onOpen = { [weak self] in
            guard let self, let url = self.appLinkBannerURL.flatMap(URL.init(string:)) else { return }
            UIApplication.shared.open(url, options: [.universalLinksOnly: true])
        }
        appLinkBanner.onClose = { [weak self] in
            guard let self else { return }
            if let host = self.appLinkBannerURL.flatMap(URL.init(string:))?.host {
                self.appLinkBannerDismissedHosts.insert(host)
            }
            self.setAppLinkBannerVisible(false, animated: true)
        }
    }

    /// Called with every address bar refresh. Looks a page up once; a reload or a load in
    /// progress (no URL yet, about:blank) keeps the banner as it is.
    func refreshAppLinkBanner() {
        guard let tab = tabManager.selectedTab else { return }
        if tab.id != appLinkBannerTabID {
            appLinkBannerTabID = tab.id
            appLinkBannerURL = nil
            setAppLinkBannerVisible(false, animated: false)
        }
        guard webAppID == nil, let urlString = tab.url, let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https", let host = url.host,
              urlString != appLinkBannerURL else {
            return
        }
        appLinkBannerURL = urlString
        guard !appLinkBannerDismissedHosts.contains(host) else {
            setAppLinkBannerVisible(false, animated: true)
            return
        }
        appLinkTargetName(url) { [weak self] name, bundleID in
            guard let self, self.appLinkBannerURL == urlString else { return }
            if let name {
                self.appLinkBanner.configure(appName: name, icon: bundleID.flatMap(appIconImage))
                self.setAppLinkBannerVisible(true, animated: true)
            } else {
                self.setAppLinkBannerVisible(false, animated: true)
            }
        }
    }

    private func setAppLinkBannerVisible(_ visible: Bool, animated: Bool) {
        let target = visible ? AppLinkBanner.height : 0
        guard appLinkBannerHeight?.constant != target else { return }
        view.layoutIfNeeded()
        appLinkBannerHeight?.constant = target
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            view.layoutIfNeeded()
            return
        }
        // Critically damped: the banner and the page move as one, no overshoot.
        UIView.animate(withDuration: visible ? 0.4 : 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }
}
