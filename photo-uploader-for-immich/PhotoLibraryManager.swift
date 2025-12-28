//
//  PhotoLibraryManager.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import Foundation
import Photos
import UIKit
import Combine
import os.log

final class PhotoLibraryManager: ObservableObject {
    static let shared = PhotoLibraryManager()

    @Published var assets: [PHAsset] = []
    @Published var isLoading = false
    @Published var selectedAssets: Set<String> = []

    private let logger = Logger(subsystem: "com.vanillezucker.photo-uploader-for-immich", category: "PhotoLibraryManager")

    private init() {}

    func fetchAllAssets() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            logger.warning("Cannot fetch assets: photo library access not authorized")
            return
        }

        logger.debug("Fetching all assets")
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.includeHiddenAssets = false

            let fetchResult = PHAsset.fetchAssets(with: fetchOptions)

            var assets: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }

            DispatchQueue.main.async {
                self?.assets = assets
                self?.isLoading = false
                self?.logger.info("Fetched \(assets.count) assets")
            }
        }
    }

    func fetchRecentAssets(limit: Int = 100) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            logger.warning("Cannot fetch assets: photo library access not authorized")
            return
        }

        logger.debug("Fetching recent assets (limit: \(limit))")
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.fetchLimit = limit
            fetchOptions.includeHiddenAssets = false

            let fetchResult = PHAsset.fetchAssets(with: fetchOptions)

            var assets: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }

            DispatchQueue.main.async {
                self?.assets = assets
                self?.isLoading = false
                self?.logger.info("Fetched \(assets.count) recent assets")
            }
        }
    }

    func fetchAssets(createdAfter date: Date) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            logger.warning("Cannot fetch assets: photo library access not authorized")
            return
        }

        logger.debug("Fetching assets created after \(date.formatted())")
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.predicate = NSPredicate(format: "creationDate > %@", date as NSDate)
            fetchOptions.includeHiddenAssets = false

            let fetchResult = PHAsset.fetchAssets(with: fetchOptions)

            var assets: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }

            DispatchQueue.main.async {
                self?.assets = assets
                self?.isLoading = false
                self?.logger.info("Fetched \(assets.count) assets created after date")
            }
        }
    }

    func toggleSelection(for asset: PHAsset) {
        if selectedAssets.contains(asset.localIdentifier) {
            selectedAssets.remove(asset.localIdentifier)
        } else {
            selectedAssets.insert(asset.localIdentifier)
        }
    }

    func selectAll() {
        selectedAssets = Set(assets.map { $0.localIdentifier })
    }

    func deselectAll() {
        selectedAssets.removeAll()
    }

    func getSelectedAssets() -> [PHAsset] {
        return assets.filter { selectedAssets.contains($0.localIdentifier) }
    }

    // MARK: - Thumbnail Loading

    func loadThumbnail(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}
