// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SQLite3

/// Manages compaction of browser history including expiration, indexing, and cleanup
class BrowserHistoryCompactionManager {
    private let settings: BrowserHistoryFSSettings
    private let baseURL: URL
    
    init(settings: BrowserHistoryFSSettings, baseURL: URL) {
        self.settings = settings
        self.baseURL = baseURL
    }
    
    /// Perform full compaction of browser history
    func performCompaction() throws {
        let processedURL = baseURL.appendingPathComponent("BrowserHistory/processed")
        let tempURL = baseURL.appendingPathComponent("BrowserHistory/temp_compaction")
        let indexURL = baseURL.appendingPathComponent("BrowserHistory/search_index.db")
        
        // Create temp directory
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        
        // Collect all entries and tombstones
        let (entries, tombstones) = try collectAllEntries(from: processedURL)
        
        // Open/create search index
        let searchIndex = try SearchIndex(at: indexURL)
        defer { searchIndex.close() }
        
        // Process entries
        let now = Date()
        let expirationDate = now.addingTimeInterval(-Double(settings.autoExpireAfterDays * 24 * 60 * 60))
        let compactionDate = now.addingTimeInterval(-Double(settings.compactAfterDays * 24 * 60 * 60))
        let tombstoneExpirationDate = now.addingTimeInterval(-Double(settings.tombstoneRetentionDays * 24 * 60 * 60))
        
        var keptEntries: [BrowserHistoryEntry] = []
        var newTombstones: [BrowserHistoryEntry] = []
        var stats = CompactionStats()
        
        // Process each entry
        for entry in entries {
            // Skip if tombstoned
            if tombstones.contains(entry.id) {
                stats.tombstonedRemoved += 1
                continue
            }
            
            // Check if expired
            if entry.timestamp < expirationDate {
                if settings.createTombstones {
                    let tombstone = entry.createTombstone(reason: .expired)
                    newTombstones.append(tombstone)
                    stats.expired += 1
                }
                continue
            }
            
            // Check privacy rules
            if shouldExclude(entry, settings: settings) {
                if settings.createTombstones {
                    let tombstone = entry.createTombstone(reason: .privacyRule)
                    newTombstones.append(tombstone)
                    stats.privacyRemoved += 1
                }
                continue
            }
            
            // Keep the entry (possibly compacted)
            if settings.enableCompaction && entry.timestamp < compactionDate {
                // Write compacted version
                let compacted = compact(entry, level: settings.compactionLevel)
                keptEntries.append(compacted)
                stats.compacted += 1
            } else {
                keptEntries.append(entry)
                stats.kept += 1
            }
            
            // Add to search index
            try searchIndex.addEntry(entry)
        }
        
        // Keep recent tombstones
        for tombstone in tombstones.values {
            if let tombstoneDate = tombstone.tombstoneDate,
               tombstoneDate > tombstoneExpirationDate {
                newTombstones.append(tombstone)
                stats.tombstonesKept += 1
            } else {
                stats.tombstonesExpired += 1
            }
        }
        
        // Write all entries to temp directory
        for entry in keptEntries + newTombstones {
            let destURL = tempURL.appendingPathComponent(entry.relativePath)
            let destDir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            let data = try JSONEncoder().encode(entry)
            try data.write(to: destURL)
        }
        
        // Atomic swap: delete old, rename temp
        try FileManager.default.removeItem(at: processedURL)
        try FileManager.default.moveItem(at: tempURL, to: processedURL)
        
        // Log stats
        print("Compaction complete: \(stats)")
    }
    
    private func collectAllEntries(from directoryURL: URL) throws -> ([BrowserHistoryEntry], [String: BrowserHistoryEntry]) {
        var entries: [BrowserHistoryEntry] = []
        var tombstones: [String: BrowserHistoryEntry] = [:]
        
        if let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "json" else { continue }
                
                let data = try Data(contentsOf: fileURL)
                let entry = try JSONDecoder().decode(BrowserHistoryEntry.self, from: data)
                
                if entry.isTombstone {
                    tombstones[entry.id] = entry
                } else {
                    entries.append(entry)
                }
            }
        }
        
        return (entries, tombstones)
    }
    
    private func shouldExclude(_ entry: BrowserHistoryEntry, settings: BrowserHistoryFSSettings) -> Bool {
        if !settings.excludePatterns.isEmpty {
            for pattern in settings.excludePatterns {
                if entry.url.range(of: pattern, options: .regularExpression) != nil {
                    return true
                }
            }
        }
        
        if !settings.includeOnlyDomains.isEmpty {
            guard let host = URL(string: entry.url)?.host else { return true }
            let matches = settings.includeOnlyDomains.contains { domain in
                host.hasSuffix(domain)
            }
            return !matches
        }
        
        return false
    }
    
    private func compact(_ entry: BrowserHistoryEntry, level: CompactionLevel) -> BrowserHistoryEntry {
        var compacted = entry
        
        switch level {
        case .minimal:
            // Keep everything
            break
            
        case .moderate:
            // Truncate title, remove referrer
            compacted.title = String(entry.title.prefix(100))
            compacted.referrer = nil
            compacted.visitDuration = nil
            
        case .aggressive:
            // Just domain as title, minimal data
            compacted.title = URL(string: entry.url)?.host ?? "Unknown"
            compacted.referrer = nil
            compacted.visitDuration = nil
        }
        
        return compacted
    }
}

/// SQLite-based search index built during compaction
class SearchIndex {
    private var db: OpaquePointer?
    
    init(at url: URL) throws {
        // Open database
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw SearchIndexError.cannotOpen
        }
        
        // Create tables if needed
        let createTable = """
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                device TEXT NOT NULL,
                url_tokens TEXT,
                title_tokens TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_timestamp ON history(timestamp);
            CREATE INDEX IF NOT EXISTS idx_device ON history(device);
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                url, title, content=history, content_rowid=rowid
            );
        """
        
        if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
            throw SearchIndexError.cannotCreateTable
        }
    }
    
    func addEntry(_ entry: BrowserHistoryEntry) throws {
        let sql = """
            INSERT OR REPLACE INTO history (id, url, title, timestamp, device, url_tokens, title_tokens)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw SearchIndexError.cannotPrepare
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, entry.id, -1, nil)
        sqlite3_bind_text(statement, 2, entry.url, -1, nil)
        sqlite3_bind_text(statement, 3, entry.title, -1, nil)
        sqlite3_bind_int64(statement, 4, Int64(entry.timestamp.timeIntervalSince1970))
        sqlite3_bind_text(statement, 5, entry.deviceName, -1, nil)
        sqlite3_bind_text(statement, 6, tokenize(entry.url), -1, nil)
        sqlite3_bind_text(statement, 7, tokenize(entry.title), -1, nil)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            throw SearchIndexError.cannotInsert
        }
        
        // Update FTS index
        let ftsSQL = "INSERT INTO history_fts(url, title) VALUES (?, ?)"
        var ftsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(ftsStatement, 1, entry.url, -1, nil)
            sqlite3_bind_text(ftsStatement, 2, entry.title, -1, nil)
            sqlite3_step(ftsStatement)
            sqlite3_finalize(ftsStatement)
        }
    }
    
    func close() {
        sqlite3_close(db)
    }
    
    private func tokenize(_ text: String) -> String {
        // Simple tokenization for search
        return text.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

enum SearchIndexError: Error {
    case cannotOpen
    case cannotCreateTable
    case cannotPrepare
    case cannotInsert
}

struct CompactionStats: CustomStringConvertible {
    var kept = 0
    var compacted = 0
    var expired = 0
    var privacyRemoved = 0
    var tombstonedRemoved = 0
    var tombstonesKept = 0
    var tombstonesExpired = 0
    
    var description: String {
        return """
        Kept: \(kept), Compacted: \(compacted), Expired: \(expired), 
        Privacy removed: \(privacyRemoved), Tombstoned: \(tombstonedRemoved),
        Tombstones kept: \(tombstonesKept), Tombstones expired: \(tombstonesExpired)
        """
    }
}