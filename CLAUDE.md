# Sushitrain Project Overview

## Project Type
iOS/macOS app for secure file synchronization using Syncthing protocol, written in Swift with a Go backend framework.

## Build Instructions

### Prerequisites
- Xcode with iOS 17.5+ SDK
- Go (see SushitrainCore/go.mod for version)
- gomobile tool: `go install golang.org/x/mobile/cmd/gomobile@latest`

### Build Steps
1. Build the Go framework:
   ```bash
   cd SushitrainCore
   PATH=$PATH:~/go/bin make
   ```

2. Open Xcode and:
   - Remove `com.apple.developer.device-information.user-assigned-device-name` entitlement
   - Set up signing with your team ID
   - Build with Cmd-B

## Known Issues
- Repository contains duplicate icon files that waste ~3.3MB:
  - Icon-iOS-Dark-1024 1.png (duplicate of Icon-iOS-Dark-1024.png)
  - Icon-macOS-256 1.png (duplicate of Icon-macOS-256.png)
  - Icon-macOS-512 1.png (duplicate of Icon-macOS-512.png)
- Large localization file (676KB) for only English language

## Testing
Check README.md or search codebase for test commands - no standard test script found yet.

## Important Files
- `/SushitrainCore/` - Go backend framework
- `/Sushitrain/` - Swift frontend code
- `Makefile` - Build configuration (assumes Homebrew Go at /opt/homebrew)
- `.gitignore` - Properly excludes build dirs and sensitive files