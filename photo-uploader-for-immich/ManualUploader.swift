//
//  ManualUploader.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import Foundation
import Photos
import Combine
import os.log

final class ManualUploader: ObservableObject {
    static let shared = ManualUploader()

    @Published private(set) var isUploading = false
    @Published private(set) var currentProgress: String = ""
    @Published private(set) var uploadedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var totalCount = 0

    private let settings = SettingsManager.shared
    private let tracker = UploadTracker.shared
    private let logger = Logger(subsystem: "com.vanillezucker.photo-uploader-for-immich", category: "ManualUploader")
    private var uploadTask: Task<Void, Never>?

    private init() {}

    func uploadPendingAssets() {
        guard !isUploading else {
            logger.debug("Upload already in progress, ignoring request")
            return
        }
        guard let enabledTimestamp = tracker.enabledTimestamp else {
            logger.warning("Cannot upload: tracking not enabled")
            return
        }

        logger.info("Starting manual upload")
        uploadTask = Task {
            await performUpload(since: enabledTimestamp)
        }
    }

    func cancelUpload() {
        logger.info("Cancelling upload")
        uploadTask?.cancel()
        uploadTask = nil
        Task { @MainActor in
            isUploading = false
            currentProgress = "Cancelled"
        }
    }

    @MainActor
    private func performUpload(since timestamp: Date) async {
        isUploading = true
        uploadedCount = 0
        failedCount = 0
        currentProgress = "Fetching assets..."

        logger.debug("Fetching assets created after \(timestamp.formatted())")

        // Fetch assets created after timestamp
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", timestamp as NSDate)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        logger.debug("Found \(fetchResult.count) assets in photo library")

        // Filter out already uploaded assets
        let uploadedIds = Set(tracker.getUploadedAssetIds())
        var assetsToUpload: [PHAsset] = []

        fetchResult.enumerateObjects { asset, _, _ in
            if !uploadedIds.contains(asset.localIdentifier) {
                assetsToUpload.append(asset)
            }
        }

        totalCount = assetsToUpload.count
        logger.info("Found \(totalCount) pending assets to upload")

        guard totalCount > 0 else {
            logger.info("No pending assets to upload")
            currentProgress = "No pending assets"
            isUploading = false
            return
        }

        // Build upload URL
        let uploadURLString = settings.fullServerURL.hasSuffix("/")
            ? settings.fullServerURL + "assets"
            : settings.fullServerURL + "/assets"

        guard let uploadURL = URL(string: uploadURLString) else {
            logger.error("Invalid server URL: \(uploadURLString, privacy: .private)")
            currentProgress = "Invalid server URL"
            isUploading = false
            return
        }

        logger.debug("Upload URL: \(uploadURLString, privacy: .private)")

        let apiKey = settings.apiKey
        guard !apiKey.isEmpty else {
            logger.error("API key not configured")
            currentProgress = "API key not configured"
            isUploading = false
            return
        }

        // Upload each asset
        for (index, asset) in assetsToUpload.enumerated() {
            if Task.isCancelled {
                logger.notice("Upload cancelled at \(index)/\(totalCount)")
                break
            }

            currentProgress = "Uploading \(index + 1) of \(totalCount)..."

            let success = await uploadAsset(asset, to: uploadURL, apiKey: apiKey)

            if success {
                uploadedCount += 1
                tracker.markAsUploaded(asset.localIdentifier)
                logger.debug("Successfully uploaded asset \(index + 1)/\(totalCount)")
            } else {
                failedCount += 1
                tracker.markAsFailed(asset.localIdentifier)
                logger.warning("Failed to upload asset \(index + 1)/\(totalCount)")
            }
        }

        if Task.isCancelled {
            currentProgress = "Cancelled - \(uploadedCount) uploaded, \(failedCount) failed"
            logger.info("Upload cancelled: \(uploadedCount) uploaded, \(failedCount) failed")
        } else {
            currentProgress = "Done - \(uploadedCount) uploaded, \(failedCount) failed"
            logger.info("Upload completed: \(uploadedCount) uploaded, \(failedCount) failed")
        }

        isUploading = false
    }

    private func uploadAsset(_ asset: PHAsset, to url: URL, apiKey: String) async -> Bool {
        // Get the primary resource
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            return false
        }

        // Export the asset data
        guard let assetData = await exportAssetData(resource: resource) else {
            return false
        }

        // Create multipart form data request
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body
        var body = Data()

        // Add deviceAssetId field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(asset.localIdentifier)\r\n".data(using: .utf8)!)

        // Add deviceId field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n".data(using: .utf8)!)
        body.append("iOS-PhotoUploader\r\n".data(using: .utf8)!)

        // Add fileCreatedAt field
        if let creationDate = asset.creationDate {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(ISO8601DateFormatter().string(from: creationDate))\r\n".data(using: .utf8)!)
        }

        // Add fileModifiedAt field
        if let modificationDate = asset.modificationDate {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(ISO8601DateFormatter().string(from: modificationDate))\r\n".data(using: .utf8)!)
        }

        // Add the file
        let filename = resource.originalFilename
        let mimeType = mimeTypeForResource(resource)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(assetData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Perform upload
        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200 || httpResponse.statusCode == 201
            }
            return false
        } catch {
            logger.error("Upload failed: \(error.localizedDescription)")
            return false
        }
    }

    private func exportAssetData(resource: PHAssetResource) async -> Data? {
        return await withCheckedContinuation { continuation in
            var data = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                data.append(chunk)
            } completionHandler: { error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

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
}
