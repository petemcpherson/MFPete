//
//  Item.swift
//  MFPete
//
//  Created by Pete McPherson on 10/1/26.
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
