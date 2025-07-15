// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation

struct BrowserHistoryEntry: Codable {
    let id: String  // SHA256 of url+timestamp
    let url: String
    let title: String
    let timestamp: Date
    let deviceName: String
    let visitDuration: TimeInterval?
    let referrer: String?
    
    // Tombstone fields
    let isTombstone: Bool
    let tombstoneDate: Date?
    let tombstoneReason: TombstoneReason?
    
    init(url: String, title: String, timestamp: Date = Date(), referrer: String? = nil) {
        self.url = url
        self.title = title
        self.timestamp = timestamp
        self.referrer = referrer
        self.deviceName = UIDevice.current.name
        self.visitDuration = nil
        
        // Not a tombstone
        self.isTombstone = false
        self.tombstoneDate = nil
        self.tombstoneReason = nil
        
        // Generate stable ID
        let idString = "\(url):\(timestamp.timeIntervalSince1970)"
        self.id = idString.sha256()
    }
    
    // Create tombstone for an entry
    static func tombstone(for entry: BrowserHistoryEntry, reason: TombstoneReason) -> BrowserHistoryEntry {
        var tombstone = entry
        tombstone.isTombstone = true
        tombstone.tombstoneDate = Date()
        tombstone.tombstoneReason = reason
        return tombstone
    }
    
    var filename: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateStr = formatter.string(from: timestamp)
        let sanitizedHost = (URL(string: url)?.host ?? "unknown")
            .replacingOccurrences(of: ".", with: "-")
        let suffix = isTombstone ? ".tombstone" : ""
        return "\(dateStr)_\(sanitizedHost)_\(id.prefix(8))\(suffix).json"
    }
    
    var relativePath: String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: timestamp)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        return "\(year)/\(month)/\(day)/\(filename)"
    }
}

enum TombstoneReason: String, Codable {
    case expired = "expired"              // Auto-expired based on age
    case userDeleted = "user_deleted"     // User manually deleted
    case privacyRule = "privacy_rule"     // Matched privacy/exclude pattern
    case storageLimit = "storage_limit"   // Exceeded storage limits
}

// App Group shared storage
class BrowserHistoryStore {
    static let appGroupIdentifier = "group.com.sushitrain.browserhistory"
    
    private var pendingEntries: [BrowserHistoryEntry] = []
    private let queue = DispatchQueue(label: "browserhistory.store", qos: .background)
    
    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .appendingPathComponent("BrowserHistory")
    }
    
    func addEntry(_ entry: BrowserHistoryEntry) {
        queue.async { [weak self] in
            self?.pendingEntries.append(entry)
            self?.flushIfNeeded()
        }
    }
    
    private func flushIfNeeded() {
        guard pendingEntries.count >= 10 || 
              pendingEntries.first?.timestamp.timeIntervalSinceNow ?? 0 < -60 else { return }
        
        flush()
    }
    
    func flush() {
        let entriesToWrite = pendingEntries
        pendingEntries.removeAll()
        
        guard let containerURL = containerURL else { return }
        
        // Write to pending directory for app to process
        let pendingURL = containerURL.appendingPathComponent("pending")
        try? FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        
        for entry in entriesToWrite {
            let fileURL = pendingURL.appendingPathComponent("\(entry.id).json")
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: fileURL)
            }
        }
    }
}

extension String {
    func sha256() -> String {
        // Simplified - would use CryptoKit in real implementation
        return self.data(using: .utf8)?.base64EncodedString() ?? ""
    }
}