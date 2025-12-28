//
//  BackgroundUploadExtension.swift
//  BackgroundUploadExtension
//
//  Created by Johannes on 27.12.25.
//

import Photos
import ExtensionFoundation
import UserNotifications
import os.lock
import os.log

@main
class BackgroundUploadExtension: PHBackgroundResourceUploadExtension {
    private let isCancelledLock = OSAllocatedUnfairLock(initialState: false)
    private let tracker = UploadTracker.shared
    private let settings = SettingsManager.shared
    private let logger = Logger(subsystem: "com.vanillezucker.photo-uploader-for-immich", category: "BackgroundUpload")

    required init() {
        logger.info("BackgroundUploadExtension initialized")
    }

    func process() -> PHBackgroundResourceUploadProcessingResult {
        logger.info("process() called - starting upload processing cycle")

        // Check if we should exit early
        if isCancelledLock.withLock({ $0 }) {
            logger.notice("process() exiting early - cancellation requested")
            return .processing
        }

        // Check if tracking is enabled
        guard let enabledTimestamp = tracker.enabledTimestamp else {
            logger.notice("process() - tracking not enabled, no timestamp set")
            return .completed
        }

        // Log current tracker state
        let uploadedCount = tracker.getUploadedAssetIds().count
        let failedCount = tracker.getFailedAssetIds().count
        logger.info("Tracker state - enabled since: \(enabledTimestamp), uploaded: \(uploadedCount), failed: \(failedCount)")

        // Log settings
        logger.debug("Server URL: \(self.settings.fullServerURL, privacy: .private)")
        logger.debug("API Key configured: \(!self.settings.apiKey.isEmpty)")

        do {
            // Retry any failed jobs
            logger.info("Starting retryFailedJobs()")
            try retryFailedJobs()

            // Acknowledge completed jobs to free up the in-flight job limit
            logger.info("Starting acknowledgeCompletedJobs()")
            try acknowledgeCompletedJobs()

            // Create new upload jobs for unprocessed assets
            logger.info("Starting createNewUploadJobs()")
            try createNewUploadJobs()

            logger.info("process() completed successfully")
            return .completed
        } catch let error as NSError {
            if error.domain == PHPhotosErrorDomain &&
               error.code == PHPhotosError.limitExceeded.rawValue {
                // Reached the in-flight job limit; return .processing
                logger.notice("In-flight job limit reached, returning .processing")
                return .processing
            }
            // Other errors
            logger.error("process() failed with NSError: \(error.localizedDescription) (domain: \(error.domain), code: \(error.code))")
            return .failure
        } catch {
            logger.error("process() failed with error: \(error.localizedDescription)")
            return .failure
        }
    }

    func notifyTermination() {
        logger.warning("notifyTermination() called - signaling process() to exit")
        // Signal the process() method to exit
        isCancelledLock.withLock { $0 = true }
    }

    // MARK: - Retry Failed Jobs

    private func retryFailedJobs() throws {
        let library = PHPhotoLibrary.shared()
        let retryableJobs = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)

        logger.info("retryFailedJobs: Found \(retryableJobs.count) jobs to retry")

        for i in 0..<retryableJobs.count {
            // Check for cancellation
            if isCancelledLock.withLock({ $0 }) {
                logger.notice("retryFailedJobs: Cancelled at job \(i)")
                return
            }

            let job = retryableJobs.object(at: i)
            let assetId = job.resource.assetLocalIdentifier
            let filename = job.resource.originalFilename

            logger.debug("retryFailedJobs: Retrying job \(i + 1)/\(retryableJobs.count) - asset: \(assetId, privacy: .private), file: \(filename, privacy: .private)")

            try library.performChangesAndWait {
                guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else {
                    self.logger.error("retryFailedJobs: Failed to create change request for job \(i)")
                    return
                }

                // Retry with the original destination
                request.retry(destination: nil)
                self.logger.debug("retryFailedJobs: Retry request submitted for job \(i)")
            }
        }

        if retryableJobs.count > 0 {
            logger.info("retryFailedJobs: Completed retrying \(retryableJobs.count) jobs")
        }
    }

    // MARK: - Acknowledge Completed Jobs

    private func acknowledgeCompletedJobs() throws {
        let library = PHPhotoLibrary.shared()
        let completedJobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)

        logger.info("acknowledgeCompletedJobs: Found \(completedJobs.count) jobs to acknowledge")

        var completedCount = 0

        for i in 0..<completedJobs.count {
            // Check for cancellation
            if isCancelledLock.withLock({ $0 }) {
                logger.notice("acknowledgeCompletedJobs: Cancelled at job \(i)")
                return
            }

            let job = completedJobs.object(at: i)

            // Update tracking - jobs in acknowledge queue are finished
            // Mark as uploaded (if it failed, it would be in retry queue)
            let assetId = job.resource.assetLocalIdentifier
            let filename = job.resource.originalFilename

            logger.debug("acknowledgeCompletedJobs: Processing job \(i + 1)/\(completedJobs.count) - asset: \(assetId, privacy: .private), file: \(filename, privacy: .private)")

            tracker.markAsUploaded(assetId)
            completedCount += 1
            logger.debug("acknowledgeCompletedJobs: Marked asset as uploaded in tracker")

            try library.performChangesAndWait {
                guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else {
                    self.logger.error("acknowledgeCompletedJobs: Failed to create change request for job \(i)")
                    return
                }
                request.acknowledge()
                self.logger.debug("acknowledgeCompletedJobs: Acknowledged job \(i)")
            }
        }

        if completedCount > 0 {
            logger.info("acknowledgeCompletedJobs: Successfully acknowledged \(completedCount) uploads")
            sendNotification(
                title: "Upload Complete",
                body: "\(completedCount) photo(s) uploaded successfully"
            )
        }
    }

    // MARK: - Create New Upload Jobs

    private func createNewUploadJobs() throws {
        let library = PHPhotoLibrary.shared()

        // Get unprocessed asset resources
        let resources = getUnprocessedResources(from: library)

        logger.info("createNewUploadJobs: Found \(resources.count) unprocessed resources")

        guard !resources.isEmpty else {
            logger.debug("createNewUploadJobs: No resources to process, returning")
            return
        }

        // Build the upload URL
        let uploadURLString = settings.fullServerURL.hasSuffix("/")
            ? settings.fullServerURL + "assets"
            : settings.fullServerURL + "/assets"

        logger.debug("createNewUploadJobs: Upload URL: \(uploadURLString, privacy: .private)")

        guard let uploadURL = URL(string: uploadURLString) else {
            logger.error("createNewUploadJobs: Invalid upload URL - \(uploadURLString, privacy: .private)")
            return
        }

        let apiKey = settings.apiKey
        if apiKey.isEmpty {
            logger.error("createNewUploadJobs: API key is empty, cannot proceed")
            return
        }

        var queuedCount = 0

        try library.performChangesAndWait { [self] in
            for (index, resource) in resources.enumerated() {
                // Check for cancellation
                if self.isCancelledLock.withLock({ $0 }) {
                    self.logger.notice("createNewUploadJobs: Cancelled at resource \(index)")
                    return
                }

                let assetId = resource.assetLocalIdentifier
                let filename = resource.originalFilename
                let fileSize = resource.value(forKey: "fileSize") as? Int64 ?? 0
                let resourceType = resource.type.rawValue

                self.logger.debug("createNewUploadJobs: Creating job \(index + 1)/\(resources.count) - asset: \(assetId, privacy: .private), file: \(filename, privacy: .private), size: \(fileSize) bytes, type: \(resourceType)")

                // Get asset dates
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
                guard let asset = fetchResult.firstObject else {
                    self.logger.warning("createNewUploadJobs: Could not fetch asset for dates: \(assetId, privacy: .private)")
                    continue
                }

                let dateFormatter = ISO8601DateFormatter()
                let createdAt = asset.creationDate.map { dateFormatter.string(from: $0) } ?? ""
                let modifiedAt = asset.modificationDate.map { dateFormatter.string(from: $0) } ?? createdAt

                // Create multipart boundary
                let boundary = "Boundary-\(UUID().uuidString)"
                let mimeType = self.mimeTypeForResource(resource)
                // Create a URL request for Immich server
                var request = URLRequest(url: uploadURL)
                request.httpMethod = "POST"

                // Add authentication
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

                // Set multipart content type
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                
                /// TODO: Technically we would have to add some required fields (like deviceId, deviceAssetId etc.) as multipart/form-data fields here. This will be overriden with the asset data though later inside the PHAssetResourceUploadJob.

                // Create the upload job - this will send raw file data, NOT multipart
                PHAssetResourceUploadJobChangeRequest.createJob(
                    destination: request,
                    resource: resource
                )

                queuedCount += 1
                self.logger.debug("createNewUploadJobs: Job created for \(filename, privacy: .private)")
            }
        }

        if queuedCount > 0 {
            logger.info("createNewUploadJobs: Successfully queued \(queuedCount) upload jobs")
            sendNotification(
                title: "Uploading Photos",
                body: "Starting upload of \(queuedCount) photo(s) to Immich"
            )
        }
    }

    // MARK: - Helper Methods

    private func getUnprocessedResources(from library: PHPhotoLibrary) -> [PHAssetResource] {
        guard let enabledTimestamp = tracker.enabledTimestamp else {
            logger.debug("getUnprocessedResources: No enabled timestamp, returning empty")
            return []
        }

        // Fetch assets created after the enabled timestamp
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", enabledTimestamp as NSDate)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        logger.debug("getUnprocessedResources: Found \(fetchResult.count) assets created after \(enabledTimestamp)")

        // Get already processed asset IDs
        let uploadedIds = Set(tracker.getUploadedAssetIds())
        let failedIds = Set(tracker.getFailedAssetIds())

        var resources: [PHAssetResource] = []
        var skippedUploaded = 0
        var skippedFailed = 0
        var noResourceCount = 0

        fetchResult.enumerateObjects { asset, _, _ in
            let assetId = asset.localIdentifier

            // Skip already uploaded
            if uploadedIds.contains(assetId) {
                skippedUploaded += 1
                return
            }

            // Skip failed (user can retry from app)
            if failedIds.contains(assetId) {
                skippedFailed += 1
                return
            }

            // Get the primary resource for the asset
            let assetResources = PHAssetResource.assetResources(for: asset)
            if let primaryResource = assetResources.first {
                resources.append(primaryResource)
                self.logger.debug("getUnprocessedResources: Queuing asset \(assetId, privacy: .private) - type: \(primaryResource.type.rawValue), file: \(primaryResource.originalFilename, privacy: .private)")
            } else {
                self.logger.warning("getUnprocessedResources: No resources found for asset: \(assetId, privacy: .private)")
                noResourceCount += 1
            }
        }

        logger.info("getUnprocessedResources: \(resources.count) to upload, \(skippedUploaded) already uploaded, \(skippedFailed) failed, \(noResourceCount) no resources")
        return resources
    }

    // MARK: - MIME Types

    private func mimeTypeForResource(_ resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier

        switch uti {
        case "public.jpeg", "public.jpg":
            return "image/jpeg"
        case "public.png":
            return "image/png"
        case "public.heic", "public.heif":
            return "image/heic"
        case "com.compuserve.gif":
            return "image/gif"
        case "public.mpeg-4":
            return "video/mp4"
        case "com.apple.quicktime-movie":
            return "video/quicktime"
        default:
            if uti.contains("image") {
                return "image/jpeg"
            } else if uti.contains("video") || uti.contains("movie") {
                return "video/mp4"
            }
            return "application/octet-stream"
        }
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) {
        logger.debug("sendNotification: Sending notification - title: '\(title)', body: '\(body)'")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let requestId = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: requestId,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [self] error in
            if let error = error {
                logger.error("sendNotification: Failed to send notification (id: \(requestId)): \(error.localizedDescription)")
            } else {
                logger.debug("sendNotification: Notification sent successfully (id: \(requestId))")
            }
        }
    }
}
