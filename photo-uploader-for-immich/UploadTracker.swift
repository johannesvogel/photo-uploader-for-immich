//
//  UploadTracker.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import Foundation
import Combine
import Photos
import os.log

/// Tracks asset upload status between the main app and the background upload extension.
/// Uses App Groups for shared storage.
///
/// Assets created after the enabledTimestamp are automatically considered for upload.
/// Only uploaded and failed assets are explicitly tracked.
final class UploadTracker: ObservableObject {
    static let shared = UploadTracker()

    private static let appGroupIdentifier = "group.com.vanillezucker.photo-uploader-for-immich"
    private let logger = Logger(subsystem: "com.vanillezucker.photo-uploader-for-immich", category: "UploadTracker")

    private enum Keys {
        static let enabledTimestamp = "enabled_timestamp"
        static let uploadedAssets = "uploaded_assets"
        static let failedAssets = "failed_assets"
    }

    private let defaults: UserDefaults

    @Published private(set) var enabledTimestamp: Date?
    @Published private(set) var uploadedCount: Int = 0
    @Published private(set) var failedCount: Int = 0

    private init() {
        // Use shared App Group container for data sharing with extension
        if let sharedDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
            self.defaults = sharedDefaults
        } else {
            // Fallback to standard defaults (extension won't be able to access)
            logger.warning("App Group not configured. Using standard UserDefaults.")
            self.defaults = UserDefaults.standard
        }
        loadEnabledTimestamp()
        refreshCounts()
    }

    // MARK: - Timestamp Management

    /// Enable tracking from the current moment
    func enableTracking() {
        let now = Date()
        defaults.set(now, forKey: Keys.enabledTimestamp)
        enabledTimestamp = now
        // Clear previous tracking data when re-enabling
        defaults.removeObject(forKey: Keys.uploadedAssets)
        defaults.removeObject(forKey: Keys.failedAssets)
        refreshCounts()
        logger.info("Tracking enabled from \(now.formatted())")
    }

    /// Disable tracking and clear timestamp
    func disableTracking() {
        defaults.removeObject(forKey: Keys.enabledTimestamp)
        enabledTimestamp = nil
        logger.info("Tracking disabled")
    }

    /// Check if tracking is enabled
    var isTrackingEnabled: Bool {
        return enabledTimestamp != nil
    }

    private func loadEnabledTimestamp() {
        enabledTimestamp = defaults.object(forKey: Keys.enabledTimestamp) as? Date
    }

    // MARK: - Asset Status

    /// Mark asset as successfully uploaded
    func markAsUploaded(_ assetId: String) {
        var uploaded = getUploadedAssetIds()
        if !uploaded.contains(assetId) {
            uploaded.append(assetId)
            defaults.set(uploaded, forKey: Keys.uploadedAssets)
            logger.debug("Marked asset as uploaded: \(assetId, privacy: .private)")
        }
        // Remove from failed if it was there
        var failed = getFailedAssetIds()
        if failed.contains(assetId) {
            failed.removeAll { $0 == assetId }
            defaults.set(failed, forKey: Keys.failedAssets)
            logger.debug("Removed asset from failed list: \(assetId, privacy: .private)")
        }
        refreshCounts()
    }

    /// Mark asset as failed to upload
    func markAsFailed(_ assetId: String) {
        var failed = getFailedAssetIds()
        if !failed.contains(assetId) {
            failed.append(assetId)
            defaults.set(failed, forKey: Keys.failedAssets)
            logger.debug("Marked asset as failed: \(assetId, privacy: .private)")
        }
        refreshCounts()
    }

    /// Check if an asset has been uploaded
    func isUploaded(_ assetId: String) -> Bool {
        return getUploadedAssetIds().contains(assetId)
    }

    /// Check if an asset has failed
    func isFailed(_ assetId: String) -> Bool {
        return getFailedAssetIds().contains(assetId)
    }

    /// Get status for an asset
    func status(for assetId: String) -> AssetUploadStatus {
        if isUploaded(assetId) {
            return .uploaded
        } else if isFailed(assetId) {
            return .failed
        } else {
            return .pending
        }
    }

    /// Get all uploaded asset IDs
    func getUploadedAssetIds() -> [String] {
        return defaults.stringArray(forKey: Keys.uploadedAssets) ?? []
    }

    /// Get all failed asset IDs
    func getFailedAssetIds() -> [String] {
        return defaults.stringArray(forKey: Keys.failedAssets) ?? []
    }

    /// Retry failed uploads by clearing their failed status
    func retryFailedUploads() {
        let count = failedCount
        defaults.set([String](), forKey: Keys.failedAssets)
        refreshCounts()
        logger.info("Retrying \(count) failed uploads")
    }

    /// Retry a single failed upload
    func retryFailed(_ assetId: String) {
        var failed = getFailedAssetIds()
        failed.removeAll { $0 == assetId }
        defaults.set(failed, forKey: Keys.failedAssets)
        refreshCounts()
        logger.debug("Retrying failed upload: \(assetId, privacy: .private)")
    }

    /// Clear all tracking data
    func clearAll() {
        defaults.removeObject(forKey: Keys.enabledTimestamp)
        defaults.removeObject(forKey: Keys.uploadedAssets)
        defaults.removeObject(forKey: Keys.failedAssets)
        enabledTimestamp = nil
        refreshCounts()
        logger.info("Cleared all tracking data")
    }

    /// Refresh counts from storage
    func refreshCounts() {
        uploadedCount = getUploadedAssetIds().count
        failedCount = getFailedAssetIds().count
    }

    /// Remove asset IDs that no longer exist in the photo library
    func cleanupDeletedAssets() {
        Task.detached(priority: .background) {
            let uploadedIds = self.getUploadedAssetIds()
            let failedIds = self.getFailedAssetIds()

            let allIds = uploadedIds + failedIds
            guard !allIds.isEmpty else { return }

            // Fetch existing assets
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allIds, options: nil)
            var existingIds = Set<String>()
            fetchResult.enumerateObjects { asset, _, _ in
                existingIds.insert(asset.localIdentifier)
            }

            // Filter to only existing assets
            let cleanedUploaded = uploadedIds.filter { existingIds.contains($0) }
            let cleanedFailed = failedIds.filter { existingIds.contains($0) }

            let removedCount = (uploadedIds.count - cleanedUploaded.count) + (failedIds.count - cleanedFailed.count)

            if removedCount > 0 {
                self.defaults.set(cleanedUploaded, forKey: Keys.uploadedAssets)
                self.defaults.set(cleanedFailed, forKey: Keys.failedAssets)

                await MainActor.run {
                    self.refreshCounts()
                }

                self.logger.info("Cleaned up \(removedCount) deleted asset(s)")
            }
        }
    }
}

// MARK: - Asset Upload Status

enum AssetUploadStatus {
    case pending
    case uploaded
    case failed
}
