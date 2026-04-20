# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Socket is a fast, minimal macOS browser with sidebar-first design. Built with Swift 6, SwiftUI, and WKWebView. Requires macOS 15.5+ and Xcode to build.

## Build & Run

```bash
# Open in Xcode (single scheme: "Socket")
open Socket.xcodeproj

# Build from command line
xcodebuild -scheme Socket -configuration Debug -arch arm64 -derivedDataPath build

# Release build (universal)
xcodebuild -scheme Socket -configuration Release -arch arm64 -arch x86_64 -derivedDataPath build
```

You must set your personal Development Team in Xcode Signing settings to build locally.

**Test targets**:

- **`SocketTests`** — XCTest unit tests. Run with:
  ```bash
  xcodebuild test -scheme Socket -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/test CODE_SIGNING_ALLOWED=NO
  ```
  Tests live in `SocketTests/` and are auto-discovered via a
  `PBXFileSystemSynchronizedRootGroup` — just drop `*.swift` files there.
  The target is declared in `Socket.xcodeproj` by `scripts/add-test-target.rb`
  (idempotent; re-run after a `git clean` that nukes the pbxproj).

- **`SocketUITests`** — XCUITest scaffold (slow, runs out-of-process). Run with:
  ```bash
  xcodebuild test -scheme Socket -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/test -only-testing:SocketUITests CODE_SIGNING_ALLOWED=NO
  ```
  Tests live in `SocketUITests/` (auto-discovered via the same sync-group pattern).
  Not part of the default scheme `Testables` — opt in via `-only-testing` so
  unit-test runs stay snappy. CI runs them only on `workflow_dispatch` / nightly.

- **Python unittests** for `.github/scripts/*` live alongside the scripts
  as `test_*.py`. Run: `python3 -m unittest discover -s .github/scripts -p "test_*.py"`

Swift unit + Python suites run on every push and PR via `.github/workflows/test.yml`.

**No SPM**: All dependencies are embedded locally in `Socket/ThirdParty/` — no `swift package resolve` needed.

## Git Workflow

- **PRs must target `dev`**, not `main` (enforced by CI). Branch from `dev` for all work.
- Releases are tagged `v*` on `main`, triggering notarized DMG builds via GitHub Actions.
- AI assistance in contributions must be disclosed per CONTRIBUTING.md.

## Architecture

### Manager-Based Pattern

The app uses specialized **Managers** for each feature domain, coordinated through environment injection:

- **BrowserManager** (`Socket/Managers/BrowserManager/`) — Current "god object" (~2800 lines) that connects all managers. Being refactored toward independent, environment-injected managers.
- **TabManager** — Tab lifecycle, persistence (atomic snapshots via `PersistenceActor`), spaces, folders, pin management.
- **ProfileManager** — Persistent profiles (each with isolated `WKWebsiteDataStore`) and ephemeral/incognito profiles using `WKWebsiteDataStore.nonPersistent()`.
- **ExtensionManager** — `WKWebExtensionController` integration (macOS 15.4+). Singleton pattern.
- **WindowRegistry** — Multi-window state tracking. Single source of truth for all open windows.
- **WebViewCoordinator** — WebView pool management for multi-window tab display.

### State Management

- **`@Observable`** (Swift Observation): `Profile`, `Space`, `Tab`, `BrowserWindowState`, `WebViewCoordinator`, `WindowRegistry`
- **`@Published` / `ObservableObject`** (Combine): `BrowserManager`, `Tab` (dual — uses both patterns), `ExtensionManager`
- **SwiftData**: Persistence layer for `SpaceEntity`, `ProfileEntity`, `TabEntity`, `FolderEntity`, `HistoryEntity`, `ExtensionEntity`
- **All state is `@MainActor`** confined for thread safety.

### App Entry & Window Hierarchy

```
SocketApp.swift          — @main entry, creates WindowGroup scene
  └─ ContentView.swift — Per-window container, registers with WindowRegistry
       └─ WindowView   — Main browser: Sidebar + WebsiteView + TopBar + StatusBar
```

**Environment injection flow**: `SocketApp` creates `BrowserManager`, `WindowRegistry`, `WebViewCoordinator`, `SocketSettingsService` and injects them as `@EnvironmentObject` / `@Environment`. Each window gets its own `BrowserWindowState`.

### Top-Level Modules

| Directory | Purpose |
|-----------|---------|
| `App/` | Entry point, AppDelegate, ContentView, window management, SocketCommands |
| `Socket/Managers/` | ~30 feature managers (business logic) |
| `Socket/Models/` | Data models and entities |
| `Socket/Components/` | SwiftUI view components |
| `Socket/Protocols/` | Protocol definitions (e.g., `TabListDataSource`) |
| `Socket/Utils/` | Utilities, WebKit extensions, Metal shaders, debug tools |
| `Socket/ThirdParty/` | Embedded dependencies (BigUIPaging, HTSymbolHook, MuteableWKWebView, swift-atomics, swift-numerics) |
| `Settings/` | Settings module |
| `CommandPalette/` | Command palette UI |
| `UI/` | Shared UI components |
| `Navigation/` | Navigation models |

## Extension System (WKWebExtension, macOS 15.4+)

The extension system is the most complex subsystem. All extension code requires `@available(macOS 15.4, *)` guards. Content script injection specifically requires macOS 15.5+.

### Key Files

| File | Purpose |
|------|---------|
| `Socket/Managers/ExtensionManager/ExtensionManager.swift` | Core manager (~3800 lines), singleton, handles full lifecycle |
| `Socket/Managers/ExtensionManager/ExtensionBridge.swift` | `WKWebExtensionTab` / `WKWebExtensionWindow` protocol adapters |
| `Socket/Models/Extension/ExtensionModels.swift` | `ExtensionEntity` (SwiftData) + `InstalledExtension` runtime model |
| `Socket/Models/BrowserConfig/BrowserConfig.swift` | Shared `WKWebViewConfiguration` factory — extension controller lives here |
| `Socket/Components/Extensions/ExtensionActionView.swift` | Toolbar buttons, popup anchor positioning |
| `Socket/Components/Extensions/ExtensionPermissionView.swift` | Permission grant/deny dialogs |
| `Socket/Components/Extensions/PopupConsoleWindow.swift` | Debug console for extension popups |
| `Socket/Utils/ExtensionUtils.swift` | Manifest validation, version checks |

### Critical: WebView Config Derivation

Tab webview configs **MUST** derive from the same `WKWebViewConfiguration` that the `WKWebExtensionController` was configured with (via `.copy()`). Creating a fresh `WKWebViewConfiguration()` and just setting `webExtensionController` on it is **NOT** enough — WebKit needs the config to share the same process pool / internal state. See `BrowserConfig.swift:webViewConfiguration(for:)`.

The chain: `BrowserConfig.shared.webViewConfiguration` (base) → ExtensionManager sets `.webExtensionController` on it → `webViewConfiguration(for: profile)` calls `.copy()` + sets profile-specific data store → tab gets that derived config.

### Installation Flow

Supported formats: `.zip`, `.appex` (Safari extension bundle), `.app` (scans `Contents/PlugIns/` for `.appex`), bare directories.

1. Extract/resolve source to get `manifest.json`
2. `ExtensionUtils.validateManifest()` — checks required fields
3. MV3 validation — verifies `background.service_worker` exists
4. `patchManifestForWebKit()` — patches world isolation, injects externally_connectable bridge
5. Create temporary `WKWebExtension` to get `uniqueIdentifier`
6. Move to `~/Library/Application Support/Socket/Extensions/{extensionId}/`
7. Grant ALL manifest permissions + host_permissions at install time (Chrome-like model)
8. Load background service worker immediately
9. Extract icon (128/64/48/32/16px from manifest icons), resolve `__MSG_key__` locale strings

### Externally Connectable Bridge

**Problem**: Pages like `account.proton.me` call `browser.runtime.sendMessage(SAFARI_EXT_ID, msg)` but Safari extension IDs don't match WKWebExtension IDs.

**Solution** (`setupExternallyConnectableBridge`): Two-layer bridge injected as content scripts:
- **PAGE world script**: Wraps `browser.runtime.sendMessage()` and `.connect()`, relays via `window.postMessage()` to the isolated world
- **ISOLATED world script** (`socket_bridge.js`): Receives postMessages, calls the real `browser.runtime.sendMessage()`, forwards responses back

`patchManifestForWebKit()` auto-injects the bridge content script entry into `manifest.json` when `externally_connectable` is present.

### Extension Bridge (ExtensionBridge.swift)

- **`ExtensionWindowAdapter`** implements `WKWebExtensionWindow`: exposes active tab, tab list, window state (minimized/maximized/fullscreen), focus/close operations, privacy status.
- **`ExtensionTabAdapter`** implements `WKWebExtensionTab`: exposes url, title, selection state, loading, pinned, muted, audio state. Returns `tab.assignedWebView` (does NOT trigger lazy init). Stable adapters cached in `tabAdapters` dictionary by `Tab.id`.

### Tab ↔ Extension Notification

Tab notifies the extension system after webview creation:
```
Tab.setupWebView()
  → ExtensionManager.shared.notifyTabOpened(tab)  // controller.didOpenTab(adapter)
  → If active: notifyTabActivated()                // controller.didActivateTab(adapter)
  → tab.didNotifyOpenToExtensions = true
```

### Permission Model

- **Install-time**: ALL manifest `permissions` + `host_permissions` auto-granted (matching Chrome behavior)
- **On load (existing extensions)**: Grants both requested + optional permissions/match patterns, enables Web Inspector
- **Runtime** (`chrome.permissions.request`): Triggers `ExtensionPermissionView` dialog via delegate

### Storage Isolation

- Extensions installed globally (`~/Library/Application Support/Socket/Extensions/{id}/`)
- Runtime storage (`chrome.storage.*`, cookies, indexedDB) isolated per profile via separate `WKWebsiteDataStore`
- On profile switch: `controller.configuration.defaultWebsiteDataStore` updated to profile-specific store

### Native Messaging

Looks up host manifests in order: `~/Library/Application Support/Socket/NativeMessagingHosts/`, then Chrome, Chromium, Edge, Brave, Mozilla paths. Protocol: 4-byte native-endian length prefix + JSON. Supports single-shot (5s timeout) and long-lived `MessagePort` connections.

### Delegate Methods (WKWebExtensionControllerDelegate)

Key delegate implementations in ExtensionManager:
- **Action popup**: Grants permissions, wakes MV3 service worker, positions popover via registered anchor views
- **Open tab/window**: Creates tabs for extension pages, handles OAuth popup flows
- **Options page**: Resolves URL from manifest (`options_ui.page` / `options_page`), opens in separate NSWindow with extension's webViewConfiguration. Includes path traversal protection.
- **Permission prompts**: `promptForPermissions()` and `promptForPermissionToAccess()` for runtime permission requests

### Diagnostics

- `probeBackgroundHealth()` — Runs at +3s and +8s after background load; uses KVC to access `_backgroundWebView` and evaluates capability probe (available APIs, permissions, errors)
- `diagnoseExtensionState()` — Full diagnostic on content scripts + messaging per extension
- Memory debug logging uses `🔍 [MEMDEBUG]` prefix

## Key Patterns

- **Lazy WebView**: `Tab.webView` is lazily initialized on first access. Tabs can exist without a loaded webview to save memory.
- **Multi-window webviews**: Same tab shown in multiple windows gets separate webview instances managed by `WebViewCoordinator`. Primary window owns the "real" webview; others get clones.
- **Profile data isolation**: Each `Profile` owns a unique `WKWebsiteDataStore`. Ephemeral profiles use non-persistent stores that are destroyed on window close.
- **Atomic persistence**: `TabManager` uses a Swift `actor` (`PersistenceActor`) for coalesced, atomic snapshot writes with backup recovery.
