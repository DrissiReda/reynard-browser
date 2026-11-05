//
//  UIViewController+SaveToFiles.swift
//  Reynard
//

import UIKit

extension UIViewController {
    /// Presents the Files export sheet so the user can save a copy of `fileURL`.
    func presentSaveToFiles(_ fileURL: URL) {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(url: fileURL, in: .exportToService)
        }
        present(picker, animated: true)
    }
}
