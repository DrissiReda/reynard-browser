//
//  BrowserViewController+Downloads.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import PassKit
import QuickLook
import UIKit

extension BrowserViewController: DownloadsCoordinatorDelegate {
    var downloadsShouldRefreshLayoutForStoreChange: Bool {
        return !sidebarCoordinator.hostsSidebar
        && browserLayout.interfaceIdiom == .pad
        && browserLayout.chromeMode == .pad
    }
    
    func downloadsCoordinator(_ coordinator: DownloadsCoordinator, didUpdate summary: DownloadStoreSummary) {
        browserChrome.updateDownload(summary)
    }
    
    func downloadsCoordinatorDidRequestLayoutRefresh(_ coordinator: DownloadsCoordinator) {
        updateBrowserLayout(animated: false)
    }
    
    // Like Safari: offer to open or save a finished download right away.
    func downloadsCoordinator(_ coordinator: DownloadsCoordinator, didComplete fileURL: URL) {
        if fileURL.pathExtension.lowercased() == "pkpass",
           let data = try? Data(contentsOf: fileURL),
           let pass = try? PKPass(data: data),
           let controller = PKAddPassesViewController(pass: pass) {
            topmostPresenter.present(controller, animated: true)
            return
        }
        if UIApplication.shared.topViewController() is UIAlertController { return }
        AlertPresenter.show(
            title: String(format: NSLocalizedString("\"%@\" Downloaded", comment: "File name"), fileURL.lastPathComponent),
            message: nil,
            buttons: [
                AlertPresenter.Button(title: NSLocalizedString("Save to Files", comment: "")) { [weak self] in
                    self?.topmostPresenter.presentSaveToFiles(fileURL)
                },
                AlertPresenter.Button(title: NSLocalizedString("Open", comment: "")) { [weak self] in
                    self?.openDownloadedFile(fileURL)
                },
                AlertPresenter.Button(title: NSLocalizedString("Close", comment: ""), style: .cancel) {},
            ]
        )
    }
    
    private var topmostPresenter: UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
    
    private func openDownloadedFile(_ fileURL: URL) {
        guard QLPreviewController.canPreview(fileURL as NSURL) else {
            let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            }
            topmostPresenter.present(sheet, animated: true)
            return
        }
        let preview = QLPreviewController()
        let source = SingleFilePreviewSource(fileURL: fileURL)
        preview.dataSource = source
        objc_setAssociatedObject(preview, &SingleFilePreviewSource.key, source, .OBJC_ASSOCIATION_RETAIN)
        topmostPresenter.present(preview, animated: true)
    }
}

/// Quick Look data source for one file; retained by its preview controller.
private final class SingleFilePreviewSource: NSObject, QLPreviewControllerDataSource {
    static var key = 0
    let fileURL: URL
    
    init(fileURL: URL) {
        self.fileURL = fileURL
    }
    
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}
