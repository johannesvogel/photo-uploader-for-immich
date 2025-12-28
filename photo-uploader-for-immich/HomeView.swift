//
//  HomeView.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import SwiftUI
import Photos

struct HomeView: View {
    @StateObject private var photoLibrary = PhotoLibraryManager.shared
    @StateObject private var uploadTracker = UploadTracker.shared
    @StateObject private var extensionManager = UploadExtensionManager.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var manualUploader = ManualUploader.shared

    @State private var photoLibraryStatus: PHAuthorizationStatus = .notDetermined

    private let columns = [
        GridItem(.adaptive(minimum: 80), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !settings.hasValidConfiguration {
                    notConfiguredView
                } else if photoLibraryStatus != .authorized {
                    noAccessView
                } else if !extensionManager.isExtensionEnabled {
                    notEnabledView
                } else if photoLibrary.isLoading {
                    ProgressView("Loading photos...")
                } else if photoLibrary.assets.isEmpty {
                    noNewAssetsView
                } else {
                    photoGridView
                }
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    uploadToolbarButton
                }
            }
            .onAppear {
                updatePhotoLibraryStatus()
                if photoLibraryStatus == .authorized {
                    extensionManager.checkExtensionStatus()
                    uploadTracker.refreshCounts()
                    fetchAssets()
                }
            }
            .refreshable {
                if photoLibraryStatus == .authorized {
                    uploadTracker.refreshCounts()
                    fetchAssets()
                }
            }
            .onChange(of: manualUploader.isUploading) { _, isUploading in
                if !isUploading {
                    uploadTracker.refreshCounts()
                }
            }
        }
    }

    private var notConfiguredView: some View {
        ContentUnavailableView {
            Label("Server Not Configured", systemImage: "server.rack")
        } description: {
            Text("Please configure your Immich server in the Settings tab.")
        }
    }

    private var noAccessView: some View {
        ContentUnavailableView {
            Label("Photo Access Required", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Please grant photo library access in the Settings tab to upload photos.")
        }
    }

    private var notEnabledView: some View {
        ContentUnavailableView {
            Label("Background Uploads Disabled", systemImage: "icloud.slash")
        } description: {
            Text("Enable background uploads in the Settings tab to start syncing your photos.")
        } actions: {
            Button("Enable Now") {
                Task {
                    await extensionManager.enableExtension()
                    fetchAssets()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var noNewAssetsView: some View {
        ContentUnavailableView {
            Label("No New Photos", systemImage: "photo.stack")
        } description: {
            if let timestamp = uploadTracker.enabledTimestamp {
                Text("No photos have been added since \(timestamp.formatted(date: .abbreviated, time: .shortened)).\n\nNew photos will automatically be uploaded to Immich.")
            } else {
                Text("No photos to upload.")
            }
        }
    }

    private var photoGridView: some View {
        VStack(spacing: 0) {
            statusHeader

            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photoLibrary.assets, id: \.localIdentifier) { asset in
                        let status = uploadTracker.status(for: asset.localIdentifier)
                        PhotoThumbnailView(
                            asset: asset,
                            status: status
                        )
                        .onTapGesture {
                            if status == .failed {
                                uploadTracker.retryFailed(asset.localIdentifier)
                            }
                        }
                    }
                }
                .padding(2)
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 0) {
            if manualUploader.isUploading {
                uploadProgressView
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(photoLibrary.assets.count) photos")
                        .font(.headline)

                    if let timestamp = uploadTracker.enabledTimestamp {
                        Text("Since \(timestamp.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    if pendingCount > 0 {
                        Label("\(pendingCount)", systemImage: "arrow.up.circle")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }

                    if uploadTracker.uploadedCount > 0 {
                        Label("\(uploadTracker.uploadedCount)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    if uploadTracker.failedCount > 0 {
                        Button {
                            uploadTracker.retryFailedUploads()
                        } label: {
                            Label("\(uploadTracker.failedCount)", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
    }

    private var uploadProgressView: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .padding(.trailing, 8)
                Text(manualUploader.currentProgress)
                    .font(.subheadline)
                Spacer()
            }

            if manualUploader.totalCount > 0 {
                ProgressView(value: Double(manualUploader.uploadedCount + manualUploader.failedCount), total: Double(manualUploader.totalCount))
                    .tint(.blue)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
    }

    private var pendingCount: Int {
        max(0, photoLibrary.assets.count - uploadTracker.uploadedCount - uploadTracker.failedCount)
    }

    @ViewBuilder
    private var uploadToolbarButton: some View {
        if manualUploader.isUploading {
            Button {
                manualUploader.cancelUpload()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        } else {
            Button {
                manualUploader.uploadPendingAssets()
            } label: {
                Label("Upload \(pendingCount)", systemImage: "icloud.and.arrow.up")
            }
            .disabled(!uploadTracker.isTrackingEnabled || pendingCount <= 0)
        }
    }

    private func updatePhotoLibraryStatus() {
        photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func fetchAssets() {
        if let timestamp = uploadTracker.enabledTimestamp {
            photoLibrary.fetchAssets(createdAfter: timestamp)
        }
    }
}

// MARK: - Photo Thumbnail View

struct PhotoThumbnailView: View {
    let asset: PHAsset
    let status: AssetUploadStatus

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(minWidth: 80, minHeight: 80)
            .clipped()

            // Video indicator
            if asset.mediaType == .video {
                Image(systemName: "video.fill")
                    .font(.caption)
                    .padding(4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(4)
                    .padding(4)
            }

            // Upload status indicator
            statusIndicator
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .overlay(statusOverlay)
        .onAppear {
            loadThumbnail()
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(4)
                .background(.ultraThinMaterial)
                .cornerRadius(4)
                .padding(4)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(4)
                .background(.ultraThinMaterial)
                .cornerRadius(4)
                .padding(4)
        case .pending:
            Image(systemName: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(4)
                .background(.ultraThinMaterial)
                .cornerRadius(4)
                .padding(4)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch status {
        case .uploaded:
            Color.green.opacity(0.15)
        case .failed:
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.red, lineWidth: 2)
        case .pending:
            EmptyView()
        }
    }

    private func loadThumbnail() {
        PhotoLibraryManager.shared.loadThumbnail(for: asset, targetSize: CGSize(width: 200, height: 200)) { image in
            self.thumbnail = image
        }
    }
}

#Preview {
    HomeView()
}
