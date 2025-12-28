//
//  photo_uploader_for_immichApp.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import SwiftUI
import SwiftData

@main
struct photo_uploader_for_immichApp: App {
    init() {
        // Clean up deleted assets from tracking database on launch
        UploadTracker.shared.cleanupDeletedAssets()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
