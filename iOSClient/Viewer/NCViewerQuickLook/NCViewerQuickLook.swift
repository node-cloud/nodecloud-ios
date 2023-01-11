//
//  NCViewerQuickLook.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 03/05/2020.
//  Copyright © 2020 Marino Faggiana. All rights reserved.
//  Copyright © 2022 Henrik Storch. All rights reserved.
//  Copyright © 2023 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//  Author Henrik Storch <henrik.storch@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import QuickLook
import NextcloudKit
import Mantis
import SwiftUI

protocol NCViewerQuickLookDelegate: AnyObject {
    func dismiss(url: URL, hasChanges: Bool)
}

@objc class NCViewerQuickLook: QLPreviewController {

    let url: URL
    var previewItems: [PreviewItem] = []
    var isEditingEnabled: Bool
    var metadata: tableMetadata?
    var delegateViewer: NCViewerQuickLookDelegate?

    // if the document has any changes (annotations)
    var hasChanges = false

    // used to display the save alert
    var parentVC: UIViewController?

    // if the Crop is presented
    var isPresentCrop = false

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc init(with url: URL, isEditingEnabled: Bool, metadata: tableMetadata?) {
        self.url = url
        self.isEditingEnabled = isEditingEnabled
        if let metadata = metadata {
            self.metadata = tableMetadata.init(value: metadata)
        }

        let previewItem = PreviewItem()
        previewItem.previewItemURL = url
        self.previewItems.append(previewItem)

        super.init(nibName: nil, bundle: nil)

        self.dataSource = self
        self.delegate = self
        self.currentPreviewItemIndex = 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard isEditingEnabled else { return }

        if metadata?.livePhoto == true {
            let error = NKError(errorCode: NCGlobal.shared.errorCharactersForbidden, errorDescription: "_message_disable_overwrite_livephoto_")
            NCContentPresenter.shared.showInfo(error: error)
        }

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: NSLocalizedString("_crop_", comment: ""), style: UIBarButtonItem.Style.plain, target: self, action: #selector(crop))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // needs to be saved bc in didDisappear presentingVC is already nil
        self.parentVC = presentingViewController
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        guard !isPresentCrop else { return }
        delegateViewer?.dismiss(url: url, hasChanges: hasChanges)
        guard isEditingEnabled, hasChanges, let metadata = metadata else { return }

        let alertController = UIAlertController(title: NSLocalizedString("_save_", comment: ""), message: nil, preferredStyle: .alert)
        var message: String?
        if metadata.livePhoto {
            message = NSLocalizedString("_message_disable_overwrite_livephoto_", comment: "")
        } else if metadata.lock {
            message = NSLocalizedString("_file_locked_no_override_", comment: "")
        } else {
            alertController.addAction(UIAlertAction(title: NSLocalizedString("_overwrite_original_", comment: ""), style: .default) { _ in
                self.saveModifiedFile(override: true)
            })
        }
        alertController.message = message

        alertController.addAction(UIAlertAction(title: NSLocalizedString("_save_as_copy_", comment: ""), style: .default) { _ in
            self.saveModifiedFile(override: false)
        })
        alertController.addAction(UIAlertAction(title: NSLocalizedString("_discard_changes_", comment: ""), style: .destructive) { _ in })
        parentVC?.present(alertController, animated: true)
    }

    @objc func crop() {

        guard let image = UIImage(contentsOfFile: url.path) else { return }
        let config = Mantis.Config()

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            config.localizationConfig.bundle = Bundle(identifier: bundleIdentifier)
            config.localizationConfig.tableName = "Localizable"
        }
        let cropViewController = Mantis.cropViewController(image: image, config: config)

        cropViewController.delegate = self
        cropViewController.modalPresentationStyle = .fullScreen

        self.isPresentCrop = true
        self.present(cropViewController, animated: true)
    }
}

extension NCViewerQuickLook: QLPreviewControllerDataSource, QLPreviewControllerDelegate {

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewItems.count
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        previewItems[index]
    }

    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        return isEditingEnabled ? .createCopy : .disabled
    }

    fileprivate func saveModifiedFile(override: Bool) {
        guard let metadata = self.metadata else { return }

        let ocId = NSUUID().uuidString
        let size = NCUtilityFileSystem.shared.getFileSize(filePath: url.path)

        if !override {
            let fileName = NCUtilityFileSystem.shared.createFileName(metadata.fileNameView, serverUrl: metadata.serverUrl, account: metadata.account)
            metadata.fileName = fileName
            metadata.fileNameView = fileName
        }

        guard let fileNamePath = CCUtility.getDirectoryProviderStorageOcId(ocId, fileNameView: metadata.fileNameView),
              NCUtilityFileSystem.shared.copyFile(atPath: url.path, toPath: fileNamePath) else { return }

        let metadataForUpload = NCManageDatabase.shared.createMetadata(
            account: metadata.account,
            user: metadata.user,
            userId: metadata.userId,
            fileName: metadata.fileName,
            fileNameView: metadata.fileNameView,
            ocId: ocId,
            serverUrl: metadata.serverUrl,
            urlBase: metadata.urlBase,
            url: url.path,
            contentType: "")

        metadataForUpload.session = NCNetworking.shared.sessionIdentifierBackground
        if override {
            metadataForUpload.sessionSelector = NCGlobal.shared.selectorUploadFileNODelete
        } else {
            metadataForUpload.sessionSelector = NCGlobal.shared.selectorUploadFile
        }
        metadataForUpload.size = size
        metadataForUpload.status = NCGlobal.shared.metadataStatusWaitUpload

        NCNetworkingProcessUpload.shared.createProcessUploads(metadatas: [metadataForUpload]) { _ in }
    }

    func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem, at modifiedContentsURL: URL) {
        // easier to handle that way than to use `.updateContents`
        // needs to be moved otherwise it will only be called once!
        guard NCUtilityFileSystem.shared.moveFile(atPath: modifiedContentsURL.path, toPath: url.path) else { return }
        hasChanges = true
    }
}

extension NCViewerQuickLook: CropViewControllerDelegate {

    func cropViewControllerDidCrop(_ cropViewController: Mantis.CropViewController, cropped: UIImage, transformation: Mantis.Transformation, cropInfo: Mantis.CropInfo) {
        cropViewController.dismiss(animated: true) {
            self.isPresentCrop = false
        }

        guard let data = cropped.jpegData(compressionQuality: 1) else { return }

        do {
            try data.write(to: self.url)
            reloadData()
        } catch {  }
    }

    func cropViewControllerDidCancel(_ cropViewController: Mantis.CropViewController, original: UIImage) {

        cropViewController.dismiss(animated: true) {
            self.isPresentCrop = false
        }
    }
}

class PreviewItem: NSObject, QLPreviewItem {
    var previewItemURL: URL?
}

// MARK: - UIViewControllerRepresentable

struct ViewerQuickLook: UIViewControllerRepresentable {

    typealias UIViewControllerType = NCViewerQuickLook

    // let fileNamePath = NSTemporaryDirectory() + metadata.fileNameView
    // CCUtility.copyFile(atPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView), toPath: fileNamePath)

    @Binding var fileNamePath: String
    @Binding var metadata: tableMetadata?

    @Environment(\.presentationMode) var presentationMode

    class Coordinator: NCViewerQuickLookDelegate {

        var parent: ViewerQuickLook
        var isModified: Bool = false

        init(_ parent: ViewerQuickLook) {
            self.parent = parent
        }

        // DELEGATE

        func dismiss(url: URL, hasChanges: Bool) {

        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIViewControllerType {
        let viewerQuickLook = NCViewerQuickLook(with: URL(fileURLWithPath: fileNamePath), isEditingEnabled: true, metadata: metadata)
        viewerQuickLook.delegateViewer = context.coordinator
        return viewerQuickLook
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) { }
}
