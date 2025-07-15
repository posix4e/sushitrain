# [WIP] Browser History Sync via Safari Extension

## Summary
This PR adds browser history synchronization functionality to Sushitrain, allowing users to sync their Safari browsing history across iOS devices using Syncthing.

## Implementation Details

### Core Features
- **Safari iOS Extension**: Captures browsing history in real-time
- **Virtual Filesystem**: Exposes history as virtual files to Syncthing (similar to PhotoFS)
- **Tombstone-based Expiration**: Distributed expiration without background tasks
- **Search Interface**: Full-text search with device/time filtering

### Technical Architecture

#### Data Flow
1. Safari extension captures page visits via content script
2. Extension writes to App Group shared container
3. BrowserHistoryFS reads from container and exposes as virtual files
4. Syncthing syncs the virtual files to other devices
5. Search interface reads from synced data

#### File Structure
```
browser-history/
├── 2025/
│   └── 01/
│       └── 15/
│           ├── 2025-01-15T10:30:00Z_example-com_abc123.json
│           └── 2025-01-15T10:31:00Z_github-com_def456.tombstone.json
└── .stignore
```

#### Tombstone System
- Entries expire after configurable days (default: 90)
- Expired entries become `.tombstone.json` files
- Tombstones sync to ensure consistent deletion across devices
- Supports reasons: expired, user_deleted, privacy_rule, storage_limit

### Files Added
- `Sushitrain/BrowserHistory.swift` - Data model with tombstone support
- `Sushitrain/BrowserHistoryFS.swift` - Virtual filesystem implementation
- `Sushitrain/BrowserHistorySearchView.swift` - Search UI
- `SafariExtension/content.js` - Page visit capture
- `SafariExtension/SafariWebExtensionHandler.swift` - Native messaging

## TODO Before Merge
- [ ] Xcode project configuration for Safari extension target
- [ ] App Group entitlements setup
- [ ] Extension Info.plist permissions
- [ ] Integration with main app UI
- [ ] Testing on real devices
- [ ] Documentation updates
- [ ] Privacy considerations review

## Testing
- [ ] Extension captures visits correctly
- [ ] Virtual filesystem exposes history
- [ ] Syncthing syncs history files
- [ ] Search finds entries across devices
- [ ] Tombstones propagate deletions
- [ ] Expiration works as expected

## Privacy Considerations
- History stored locally until synced
- Exclude patterns for sensitive URLs
- All sync is E2E encrypted via Syncthing
- User controls retention period

## Future Enhancements
- [ ] Visit duration tracking
- [ ] Frecency-based search ranking
- [ ] Bulk operations (delete by domain/date)
- [ ] Export functionality
- [ ] macOS Safari support

🤖 Generated with [Claude Code](https://claude.ai/code)