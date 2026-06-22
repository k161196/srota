//
//  Item.swift
//  srota
//
//  Created by Kiran Yadav on 22/06/26.
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
