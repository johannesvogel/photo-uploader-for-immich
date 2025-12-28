import Foundation
import Combine
import os.log

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private static let appGroupIdentifier = "group.com.vanillezucker.photo-uploader-for-immich"

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.vanillezucker.photo-uploader-for-immich", category: "SettingsManager")

    private enum Keys {
        static let serverURL = "immich_server_url"
        static let serverPort = "immich_server_port"
        static let serverPath = "immich_server_path"
        static let apiKey = "immich_api_key"
    }

    @Published var serverURL: String {
        didSet {
            defaults.set(serverURL, forKey: Keys.serverURL)
        }
    }

    @Published var serverPort: String {
        didSet {
            defaults.set(serverPort, forKey: Keys.serverPort)
        }
    }

    @Published var serverPath: String {
        didSet {
            defaults.set(serverPath, forKey: Keys.serverPath)
        }
    }

    @Published var apiKey: String {
        didSet {
            defaults.set(apiKey, forKey: Keys.apiKey)
        }
    }

    var hasValidConfiguration: Bool {
        !serverURL.isEmpty && !apiKey.isEmpty
    }

    var fullServerURL: String {
        var url = serverURL

        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }

        if !serverPort.isEmpty {
            url += ":" + serverPort
        }

        if !serverPath.isEmpty {
            let path = serverPath.hasPrefix("/") ? serverPath : "/" + serverPath
            url += path
        }

        return url
    }

    private static let defaultPort = "443"
    private static let defaultPath = "/api/"

    private init() {
        // Use shared App Group container for data sharing with extension
        if let sharedDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
            self.defaults = sharedDefaults
        } else {
            logger.warning("App Group not configured. Using standard UserDefaults.")
            self.defaults = UserDefaults.standard
        }

        self.serverURL = defaults.string(forKey: Keys.serverURL) ?? ""

        let storedPort = defaults.string(forKey: Keys.serverPort)
        self.serverPort = (storedPort?.isEmpty ?? true) ? Self.defaultPort : storedPort!

        let storedPath = defaults.string(forKey: Keys.serverPath)
        self.serverPath = (storedPath?.isEmpty ?? true) ? Self.defaultPath : storedPath!

        self.apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
    }

    func clearAllSettings() {
        serverURL = ""
        serverPort = Self.defaultPort
        serverPath = Self.defaultPath
        apiKey = ""

        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.serverPort)
        defaults.removeObject(forKey: Keys.serverPath)
        defaults.removeObject(forKey: Keys.apiKey)
    }
}
