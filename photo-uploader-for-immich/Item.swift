//
//  Item.swift
//  photo-uploader-for-immich
//
//  Created by Johannes on 27.12.25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
