// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
@preconcurrency import SushitrainCore
import Foundation

let browserHistoryFSType: String = "sushitrain.browserhistory.v1"

struct BrowserHistoryFSSettings: Codable {
    var maxDaysToSync: Int = 90
    var excludePatterns: [String] = []
    var includeOnlyDomains: [String] = []
    
    // Expiration settings
    var autoExpireAfterDays: Int = 90
    var respectTombstones: Bool = true  // Honor tombstones from other devices
    var createTombstones: Bool = true   // Create tombstones when expiring
}

private class BrowserHistoryFS: NSObject {
    private let cacheLock = DispatchSemaphore(value: 1)
    private var cachedRoots: [String: StaticCustomFSDirectory] = [:]
    private let store = BrowserHistoryStore()
    
    override init() {
        super.init()
        registerWithCore()
    }
    
    private func registerWithCore() {
        SushitrainRegisterCustomFS(browserHistoryFSType) { path in
            return self.instantiateRoot(path: path ?? "")
        }
    }
    
    private func instantiateRoot(path: String) -> SushitrainCustomFileEntryProtocol? {
        cacheLock.wait()
        defer { cacheLock.signal() }
        
        // Parse settings from path (like PhotoFS does)
        let settings: BrowserHistoryFSSettings
        if let data = path.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(BrowserHistoryFSSettings.self, from: data) {
            settings = decoded
        } else {
            settings = BrowserHistoryFSSettings()
        }
        
        // Check cache
        if let cached = cachedRoots[path] {
            return cached
        }
        
        // Build virtual tree
        let root = buildVirtualTree(settings: settings)
        cachedRoots[path] = root
        
        // Invalidate cache after 60 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.cacheLock.wait()
            self?.cachedRoots.removeValue(forKey: path)
            self?.cacheLock.signal()
        }
        
        return root
    }
    
    private func buildVirtualTree(settings: BrowserHistoryFSSettings) -> StaticCustomFSDirectory {
        var rootChildren: [CustomFSEntry] = []
        
        // Add .stfolder marker
        rootChildren.append(StaticCustomFSDirectory(".stfolder", children: []))
        
        // Add .stignore
        let ignoreContent = """
        # Browser History Sync
        .DS_Store
        *.tmp
        """
        rootChildren.append(BrowserHistoryFile(".stignore", data: ignoreContent.data(using: .utf8)!))
        
        // Process pending entries from extension
        processPendingEntries()
        
        // Build date-based directory structure from processed entries
        let historyRoot = buildHistoryTree(settings: settings)
        rootChildren.append(historyRoot)
        
        return StaticCustomFSDirectory("", children: rootChildren)
    }
    
    private func processPendingEntries() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BrowserHistoryStore.appGroupIdentifier
        ) else { return }
        
        let pendingURL = containerURL.appendingPathComponent("BrowserHistory/pending")
        let processedURL = containerURL.appendingPathComponent("BrowserHistory/processed")
        
        try? FileManager.default.createDirectory(at: processedURL, withIntermediateDirectories: true)
        
        // Move pending entries to processed directory with proper structure
        if let files = try? FileManager.default.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let entry = try? JSONDecoder().decode(BrowserHistoryEntry.self, from: data) {
                    
                    let destURL = processedURL.appendingPathComponent(entry.relativePath)
                    let destDir = destURL.deletingLastPathComponent()
                    
                    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: file, to: destURL)
                }
            }
        }
    }
    
    private func buildHistoryTree(settings: BrowserHistoryFSSettings) -> CustomFSEntry {
        var yearDirs: [String: MutableCustomFSDirectory] = [:]
        var seenIds = Set<String>()  // Track seen IDs to handle tombstones
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BrowserHistoryStore.appGroupIdentifier
        ) else {
            return StaticCustomFSDirectory("history", children: [])
        }
        
        let processedURL = containerURL.appendingPathComponent("BrowserHistory/processed")
        let cutoffDate = Date().addingTimeInterval(-Double(settings.maxDaysToSync * 24 * 60 * 60))
        let expirationDate = Date().addingTimeInterval(-Double(settings.autoExpireAfterDays * 24 * 60 * 60))
        
        // First pass: collect all tombstones
        var tombstones = Set<String>()
        if settings.respectTombstones {
            if let enumerator = FileManager.default.enumerator(at: processedURL, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent.contains(".tombstone.json") {
                        if let data = try? Data(contentsOf: fileURL),
                           let entry = try? JSONDecoder().decode(BrowserHistoryEntry.self, from: data),
                           entry.isTombstone {
                            tombstones.insert(entry.id)
                        }
                    }
                }
            }
        }
        
        // Second pass: process entries and apply expiration
        if let enumerator = FileManager.default.enumerator(at: processedURL, includingPropertiesForKeys: [.creationDateKey]) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "json" else { continue }
                guard !fileURL.lastPathComponent.contains(".tombstone") else { continue }
                
                if let data = try? Data(contentsOf: fileURL),
                   let entry = try? JSONDecoder().decode(BrowserHistoryEntry.self, from: data) {
                    
                    // Skip if tombstoned
                    if tombstones.contains(entry.id) { continue }
                    
                    // Check if expired
                    if entry.timestamp < expirationDate && settings.createTombstones {
                        // Create tombstone
                        let tombstone = BrowserHistoryEntry.tombstone(for: entry, reason: .expired)
                        let tombstoneURL = processedURL.appendingPathComponent(tombstone.relativePath)
                        let tombstoneDir = tombstoneURL.deletingLastPathComponent()
                        
                        try? FileManager.default.createDirectory(at: tombstoneDir, withIntermediateDirectories: true)
                        if let tombstoneData = try? JSONEncoder().encode(tombstone) {
                            try? tombstoneData.write(to: tombstoneURL)
                        }
                        
                        // Delete original
                        try? FileManager.default.removeItem(at: fileURL)
                        continue
                    }
                    
                    // Apply filters
                    guard entry.timestamp > cutoffDate else { continue }
                    
                    if !settings.excludePatterns.isEmpty {
                        let matches = settings.excludePatterns.contains { pattern in
                            entry.url.range(of: pattern, options: .regularExpression) != nil
                        }
                        if matches {
                            // Create privacy tombstone if configured
                            if settings.createTombstones {
                                let tombstone = BrowserHistoryEntry.tombstone(for: entry, reason: .privacyRule)
                                let tombstoneURL = processedURL.appendingPathComponent(tombstone.relativePath)
                                let tombstoneDir = tombstoneURL.deletingLastPathComponent()
                                
                                try? FileManager.default.createDirectory(at: tombstoneDir, withIntermediateDirectories: true)
                                if let tombstoneData = try? JSONEncoder().encode(tombstone) {
                                    try? tombstoneData.write(to: tombstoneURL)
                                }
                                
                                // Delete original
                                try? FileManager.default.removeItem(at: fileURL)
                            }
                            continue
                        }
                    }
                    
                    if !settings.includeOnlyDomains.isEmpty {
                        guard let host = URL(string: entry.url)?.host else { continue }
                        let matches = settings.includeOnlyDomains.contains { domain in
                            host.hasSuffix(domain)
                        }
                        if !matches { continue }
                    }
                    
                    // Build directory structure
                    let components = entry.relativePath.split(separator: "/")
                    if components.count >= 4 {
                        let year = String(components[0])
                        let month = String(components[1])
                        let day = String(components[2])
                        let filename = String(components[3])
                        
                        let yearDir = yearDirs[year] ?? MutableCustomFSDirectory(year, children: [])
                        yearDirs[year] = yearDir
                        
                        let monthDir = yearDir.getOrCreateSubdirectory(month)
                        let dayDir = monthDir.getOrCreateSubdirectory(day)
                        
                        dayDir.place(BrowserHistoryFile(filename, data: data, entry: entry))
                        seenIds.insert(entry.id)
                    }
                }
            }
        }
        
        let sortedYears = yearDirs.keys.sorted()
        let children = sortedYears.compactMap { yearDirs[$0]?.freeze() }
        
        return StaticCustomFSDirectory("history", children: children)
    }
}

// Custom file entry for browser history
private class BrowserHistoryFile: CustomFSEntry {
    let data: Data
    let entry: BrowserHistoryEntry?
    
    init(_ name: String, data: Data, entry: BrowserHistoryEntry? = nil) {
        self.data = data
        self.entry = entry
        super.init(name)
    }
    
    override func data() throws -> Data {
        return self.data
    }
    
    override func bytes(_ ret: UnsafeMutablePointer<Int>?) throws {
        ret?.pointee = self.data.count
    }
    
    override func modifiedTime() -> Int64 {
        return Int64((entry?.timestamp ?? Date()).timeIntervalSince1970)
    }
}

// Mutable directory for building tree
private class MutableCustomFSDirectory: CustomFSDirectory {
    let name: String
    var childrenMap: [String: CustomFSEntry] = [:]
    
    init(_ name: String, children: [CustomFSEntry]) {
        self.name = name
        for child in children {
            childrenMap[child.name()] = child
        }
    }
    
    func getOrCreateSubdirectory(_ name: String) -> CustomFSDirectory {
        if let existing = childrenMap[name] as? MutableCustomFSDirectory {
            return existing
        }
        let newDir = MutableCustomFSDirectory(name, children: [])
        childrenMap[name] = newDir
        return newDir
    }
    
    func place(_ entry: CustomFSEntry) {
        childrenMap[entry.name()] = entry
    }
    
    func freeze() -> StaticCustomFSDirectory {
        let children = childrenMap.values.sorted { $0.name() < $1.name() }
        return StaticCustomFSDirectory(name, children: children)
    }
}

// Singleton instance
private let browserHistoryFS = BrowserHistoryFS()