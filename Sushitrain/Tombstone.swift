// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation

/// Reasons why an entry was tombstoned
enum TombstoneReason: String, Codable {
    case expired = "expired"              // Auto-expired based on age
    case userDeleted = "user_deleted"     // User manually deleted
    case privacyRule = "privacy_rule"     // Matched privacy/exclude pattern
    case storageLimit = "storage_limit"   // Exceeded storage limits
}

/// Protocol for entries that support tombstoning
protocol Tombstonable: Codable {
    var id: String { get }
    var isTombstone: Bool { get }
    var tombstoneDate: Date? { get }
    var tombstoneReason: TombstoneReason? { get }
    
    func createTombstone(reason: TombstoneReason) -> Self
}

/// Generic tombstone manager for handling tombstoned entries
class TombstoneManager<T: Tombstonable> {
    private var tombstones = Set<String>()
    
    /// Load all tombstones from a directory
    func loadTombstones(from directoryURL: URL) {
        tombstones.removeAll()
        
        if let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.contains(".tombstone.json") {
                    if let data = try? Data(contentsOf: fileURL),
                       let entry = try? JSONDecoder().decode(T.self, from: data),
                       entry.isTombstone {
                        tombstones.insert(entry.id)
                    }
                }
            }
        }
    }
    
    /// Check if an entry is tombstoned
    func isTombstoned(_ id: String) -> Bool {
        return tombstones.contains(id)
    }
    
    /// Add a tombstone ID
    func addTombstone(_ id: String) {
        tombstones.insert(id)
    }
    
    /// Get all tombstone IDs
    var allTombstoneIds: Set<String> {
        return tombstones
    }
    
    /// Filter out tombstoned entries from a collection
    func filterTombstoned<C: Collection>(_ entries: C) -> [T] where C.Element == T {
        return entries.filter { !isTombstoned($0.id) }
    }
    
    /// Create and write a tombstone file
    func createTombstoneFile(for entry: T, reason: TombstoneReason, at baseURL: URL, relativePath: String) throws {
        let tombstone = entry.createTombstone(reason: reason)
        let tombstoneURL = baseURL.appendingPathComponent(relativePath)
        let tombstoneDir = tombstoneURL.deletingLastPathComponent()
        
        try FileManager.default.createDirectory(at: tombstoneDir, withIntermediateDirectories: true)
        let tombstoneData = try JSONEncoder().encode(tombstone)
        try tombstoneData.write(to: tombstoneURL)
        
        addTombstone(entry.id)
    }
}

/// Extension to make file operations easier
extension Tombstonable {
    /// Generate a tombstone filename from the original filename
    static func tombstoneFilename(from originalFilename: String) -> String {
        if let dotIndex = originalFilename.lastIndex(of: ".") {
            let name = originalFilename[..<dotIndex]
            let ext = originalFilename[dotIndex...]
            return "\(name).tombstone\(ext)"
        }
        return "\(originalFilename).tombstone"
    }
}