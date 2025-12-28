//
//  UploadExtensionManager.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import Foundation
import Photos
import Combine
import os.log

/// Manages the background upload extension lifecycle
final class UploadExtensionManager: ObservableObject {
    static let shared = UploadExtensionManager()

    @Published private(set) var isExtensionEnabled = false
    @Published private(set) var lastError: String?

    private let tracker = UploadTracker.shared
    private let logger = Logger(subsystem: "com.vanillezucker.photo-uploader-for-immich", category: "UploadExtensionManager")

    private init() {
        checkExtensionStatus()
    }

    /// Check if the extension is currently enabled
    func checkExtensionStatus() {
        let library = PHPhotoLibrary.shared()
        let wasEnabled = isExtensionEnabled
        isExtensionEnabled = library.uploadJobExtensionEnabled
        if wasEnabled != isExtensionEnabled {
            logger.info("Extension status changed: \(self.isExtensionEnabled ? "enabled" : "disabled")")
        }
    }

    /// Enable the background upload extension
    /// Requires full photo library authorization (.authorized)
    func enableExtension() async -> Bool {
        logger.info("Attempting to enable upload extension")
        let library = PHPhotoLibrary.shared()

        // First, ensure we have full library access
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            logger.warning("Photo library access not authorized, cannot enable extension")
            await MainActor.run {
                lastError = "Full photo library access is required to enable background uploads."
            }
            return false
        }

        // Enable the extension
        do {
            try library.setUploadJobExtensionEnabled(true)
            await MainActor.run {
                // Set the tracking timestamp - all assets created after this will be uploaded
                tracker.enableTracking()
                isExtensionEnabled = true
                lastError = nil
            }
            logger.info("Upload extension enabled successfully")
            return true
        } catch {
            await MainActor.run {
                lastError = "Failed to enable extension: \(error.localizedDescription)"
                isExtensionEnabled = false
            }
            logger.error("Failed to enable extension: \(error.localizedDescription)")
            return false
        }
    }

    /// Disable the background upload extension
    func disableExtension() {
        logger.info("Attempting to disable upload extension")
        let library = PHPhotoLibrary.shared()

        do {
            try library.setUploadJobExtensionEnabled(false)
            tracker.disableTracking()
            isExtensionEnabled = false
            lastError = nil
            logger.info("Upload extension disabled successfully")
        } catch {
            lastError = "Failed to disable extension: \(error.localizedDescription)"
            logger.error("Failed to disable extension: \(error.localizedDescription)")
        }
    }
}
