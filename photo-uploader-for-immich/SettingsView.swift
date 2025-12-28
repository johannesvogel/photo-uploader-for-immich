//
//  SettingsView.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import SwiftUI
import Photos
import UserNotifications

enum ConnectionTestResult: Equatable {
    case none
    case testing
    case success
    case invalidAPIKey
    case insufficientPermissions
    case error(String)
}

struct SettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var extensionManager = UploadExtensionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var connectionTestResult: ConnectionTestResult = .none
    @State private var photoLibraryStatus: PHAuthorizationStatus = .notDetermined
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Server URL")
                        Spacer()
                        TextField("", text: $settings.serverURL)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", text: $settings.serverPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }

                    HStack {
                        Text("Path")
                        Spacer()
                        TextField("", text: $settings.serverPath)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }
                } header: {
                    Text("Immich Server")
                } footer: {
                    if settings.hasValidConfiguration {
                        Text("Full URL: \(settings.fullServerURL)")
                    } else {
                        Text("Enter your Immich server address (e.g., immich.example.com)")
                    }
                }

                Section {
                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("", text: $settings.apiKey)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Your API key needs the 'asset.upload' permission.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        if connectionTestResult == .testing {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Test Connection")
                                Spacer()
                            }
                        } else {
                            Text("Test Connection")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!settings.hasValidConfiguration || connectionTestResult == .testing)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    if connectionTestResult != .none && connectionTestResult != .testing {
                        connectionResultView
                    }
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        photoLibraryStatusLabel
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    if photoLibraryStatus != .authorized {
                        Button {
                            requestPhotoLibraryAccess()
                        } label: {
                            Text(photoLibraryStatus == .notDetermined ? "Grant Access" : "Open Settings")
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("Photo Library")
                } footer: {
                    Text("Full photo library access is required to upload photos to Immich.")
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        notificationStatusLabel
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    if notificationStatus != .authorized {
                        Button {
                            requestNotificationAccess()
                        } label: {
                            Text(notificationStatus == .notDetermined ? "Enable Notifications" : "Open Settings")
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Receive notifications about upload progress and completion.")
                }

                Section {
                    Toggle("Background Uploads", isOn: Binding(
                        get: { extensionManager.isExtensionEnabled },
                        set: { newValue in
                            if newValue {
                                Task {
                                    await extensionManager.enableExtension()
                                }
                            } else {
                                extensionManager.disableExtension()
                            }
                        }
                    ))
                    .disabled(photoLibraryStatus != .authorized)

                    if let error = extensionManager.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                } header: {
                    Text("Background Uploads")
                } footer: {
                    Text("When enabled, photos are uploaded in the background even when the app is closed. Requires full photo library access.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                updatePhotoLibraryStatus()
                updateNotificationStatus()
                extensionManager.checkExtensionStatus()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    updatePhotoLibraryStatus()
                    updateNotificationStatus()
                    extensionManager.checkExtensionStatus()
                }
            }
        }
    }

    @ViewBuilder
    private var connectionResultView: some View {
        switch connectionTestResult {
        case .success:
            Label("Connection successful", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalidAPIKey:
            Label("Invalid API key", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .insufficientPermissions:
            Label("Insufficient API key permissions", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .error(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .none, .testing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var photoLibraryStatusLabel: some View {
        switch photoLibraryStatus {
        case .authorized:
            Label("Full Access", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .limited:
            Label("Limited Access", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .restricted:
            Label("Restricted", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notDetermined:
            Text("Not Requested")
                .foregroundStyle(.secondary)
        @unknown default:
            Text("Unknown")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var notificationStatusLabel: some View {
        switch notificationStatus {
        case .authorized:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .provisional:
            Label("Provisional", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notDetermined:
            Text("Not Requested")
                .foregroundStyle(.secondary)
        case .ephemeral:
            Label("Ephemeral", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        @unknown default:
            Text("Unknown")
                .foregroundStyle(.secondary)
        }
    }

    private func updatePhotoLibraryStatus() {
        photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func requestPhotoLibraryAccess() {
        if photoLibraryStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    photoLibraryStatus = status
                }
            }
        } else {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func updateNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationStatus = settings.authorizationStatus
            }
        }
    }

    private func requestNotificationAccess() {
        if notificationStatus == .notDetermined {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    notificationStatus = granted ? .authorized : .denied
                }
            }
        } else {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func testConnection() {
        connectionTestResult = .testing

        let urlString = settings.fullServerURL.hasSuffix("/")
            ? settings.fullServerURL + "api-keys/me"
            : settings.fullServerURL + "/api-keys/me"

        guard let url = URL(string: urlString) else {
            setConnectionResult(.error("Invalid URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    setConnectionResult(.error(error.localizedDescription))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    setConnectionResult(.error("Invalid response"))
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    setConnectionResult(.success)
                case 401:
                    setConnectionResult(.invalidAPIKey)
                case 403:
                    setConnectionResult(.insufficientPermissions)
                default:
                    setConnectionResult(.error("HTTP \(httpResponse.statusCode)"))
                }
            }
        }.resume()
    }

    private func setConnectionResult(_ result: ConnectionTestResult) {
        connectionTestResult = result
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if connectionTestResult == result {
                connectionTestResult = .none
            }
        }
    }
}

#Preview {
    SettingsView()
}
