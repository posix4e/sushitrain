// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI

struct BrowserHistorySearchView: View {
    @State private var searchText = ""
    @State private var searchResults: [BrowserHistoryEntry] = []
    @State private var isSearching = false
    @State private var selectedTimeRange = TimeRange.all
    @State private var selectedDevice: String? = nil
    
    @StateObject private var searcher = BrowserHistorySearcher()
    
    enum TimeRange: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "Past Week"
        case month = "Past Month"
        
        var interval: TimeInterval? {
            switch self {
            case .all: return nil
            case .today: return 24 * 60 * 60
            case .week: return 7 * 24 * 60 * 60
            case .month: return 30 * 24 * 60 * 60
            }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Search history...", text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit {
                            performSearch()
                        }
                    
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            searchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                
                // Filters
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        // Time range filter
                        Menu {
                            ForEach(TimeRange.allCases, id: \.self) { range in
                                Button(action: {
                                    selectedTimeRange = range
                                    performSearch()
                                }) {
                                    HStack {
                                        Text(range.rawValue)
                                        if selectedTimeRange == range {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label(selectedTimeRange.rawValue, systemImage: "calendar")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                        }
                        
                        // Device filter
                        if !searcher.availableDevices.isEmpty {
                            Menu {
                                Button(action: {
                                    selectedDevice = nil
                                    performSearch()
                                }) {
                                    HStack {
                                        Text("All Devices")
                                        if selectedDevice == nil {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                
                                ForEach(searcher.availableDevices, id: \.self) { device in
                                    Button(action: {
                                        selectedDevice = device
                                        performSearch()
                                    }) {
                                        HStack {
                                            Text(device)
                                            if selectedDevice == device {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label(selectedDevice ?? "All Devices", systemImage: "iphone")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Divider()
                
                // Results
                if isSearching {
                    ProgressView("Searching...")
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    Text("No results found")
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(searchResults) { entry in
                        BrowserHistoryRow(entry: entry)
                            .contextMenu {
                                Button(action: {
                                    UIPasteboard.general.string = entry.url
                                }) {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }
                                
                                Button(action: {
                                    if let url = URL(string: entry.url) {
                                        UIApplication.shared.open(url)
                                    }
                                }) {
                                    Label("Open in Safari", systemImage: "safari")
                                }
                                
                                ShareLink(item: URL(string: entry.url)!)
                            }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Browser History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: {
                            searcher.rebuildIndex()
                        }) {
                            Label("Rebuild Index", systemImage: "arrow.clockwise")
                        }
                        
                        Button(action: {
                            // Show settings
                        }) {
                            Label("Settings", systemImage: "gear")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await searcher.loadIndex()
        }
    }
    
    private func performSearch() {
        isSearching = true
        
        Task {
            let results = await searcher.search(
                query: searchText,
                timeRange: selectedTimeRange.interval,
                device: selectedDevice
            )
            
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }
}

struct BrowserHistoryRow: View {
    let entry: BrowserHistoryEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
                .lineLimit(1)
            
            Text(entry.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            HStack {
                Text(entry.deviceName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                
                Spacer()
                
                Text(RelativeDateTimeFormatter().localizedString(for: entry.timestamp, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// Search implementation
class BrowserHistorySearcher: ObservableObject {
    @Published var availableDevices: [String] = []
    private var searchIndex: [BrowserHistoryEntry] = []
    private var tombstones = Set<String>()  // Track tombstoned IDs
    
    func loadIndex() async {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BrowserHistoryStore.appGroupIdentifier
        ) else { return }
        
        let processedURL = containerURL.appendingPathComponent("BrowserHistory/processed")
        
        var entries: [BrowserHistoryEntry] = []
        var devices = Set<String>()
        tombstones.removeAll()
        
        // First, load all tombstones
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
        
        // Then load entries, skipping tombstoned ones
        if let enumerator = FileManager.default.enumerator(at: processedURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "json" else { continue }
                guard !fileURL.lastPathComponent.contains(".tombstone") else { continue }
                
                if let data = try? Data(contentsOf: fileURL),
                   let entry = try? JSONDecoder().decode(BrowserHistoryEntry.self, from: data) {
                    
                    // Skip if tombstoned
                    if tombstones.contains(entry.id) { continue }
                    
                    entries.append(entry)
                    devices.insert(entry.deviceName)
                }
            }
        }
        
        await MainActor.run {
            self.searchIndex = entries.sorted { $0.timestamp > $1.timestamp }
            self.availableDevices = Array(devices).sorted()
        }
    }
    
    func search(query: String, timeRange: TimeInterval?, device: String?) async -> [BrowserHistoryEntry] {
        // Implement search logic
        // - Full text search in title and URL
        // - Filter by time range
        // - Filter by device
        // - Sort by frecency (frequency + recency)
        
        return searchIndex.filter { entry in
            // Skip tombstoned entries (double-check)
            guard !tombstones.contains(entry.id) else { return false }
            
            let matchesQuery = query.isEmpty || 
                entry.title.localizedCaseInsensitiveContains(query) ||
                entry.url.localizedCaseInsensitiveContains(query)
            
            let matchesTime = timeRange == nil ||
                entry.timestamp.timeIntervalSinceNow > -(timeRange!)
            
            let matchesDevice = device == nil || entry.deviceName == device
            
            return matchesQuery && matchesTime && matchesDevice
        }
    }
    
    func rebuildIndex() {
        Task {
            await loadIndex()
        }
    }
    
    func deleteEntry(_ entry: BrowserHistoryEntry) async {
        // Create user-deleted tombstone
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BrowserHistoryStore.appGroupIdentifier
        ) else { return }
        
        let processedURL = containerURL.appendingPathComponent("BrowserHistory/processed")
        
        // Create tombstone
        let tombstone = BrowserHistoryEntry.tombstone(for: entry, reason: .userDeleted)
        let tombstoneURL = processedURL.appendingPathComponent(tombstone.relativePath)
        let tombstoneDir = tombstoneURL.deletingLastPathComponent()
        
        try? FileManager.default.createDirectory(at: tombstoneDir, withIntermediateDirectories: true)
        if let tombstoneData = try? JSONEncoder().encode(tombstone) {
            try? tombstoneData.write(to: tombstoneURL)
        }
        
        // Delete original file
        let originalURL = processedURL.appendingPathComponent(entry.relativePath)
        try? FileManager.default.removeItem(at: originalURL)
        
        // Update local state
        tombstones.insert(entry.id)
        await loadIndex()
    }
}

// Make BrowserHistoryEntry Identifiable for SwiftUI
extension BrowserHistoryEntry: Identifiable {}