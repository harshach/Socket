# Safari Sidebar

This repo now has two browser code paths:

- repo root
  The primary browser base is now [Nook](https://github.com/nook-browser/nook), checked into this repo root as an AppKit/SwiftUI/WebKit macOS browser with real browser surfaces already implemented: downloads, extensions, settings, profiles, split view, and a sidebar-first shell.
- `Legacy/SwiftPMShell`
  The earlier SwiftPM proof-of-concept shell is preserved only as reference material.

## Current Direction

The active implementation work is happening directly on the Nook codebase in this repo root, with Sigma-style behavior layered on top of Nook’s existing browser substrate instead of rebuilding browser chrome from scratch.

The app has been patched toward the Sigma design in these areas:

- Sidebar-only chrome is enforced. The horizontal top-of-window tab layout is disabled for this build.
- Safari-style top address chrome is the default.
- Sigma command mode can be enabled from Settings and now supports bare-key shortcuts such as `j`, `k`, `d`, `/`, and `Space` when the user is not typing in a field.
- The shortcuts settings surface now supports multiple bindings for the same action instead of one binding per action.
- `Cmd`-click creates Sigma-style child tabs via `parentTabId`.
- `Shift`-click opens links into the right split pane.
- Sidebar regular tabs render in hierarchical display order with indentation for child pages.

## Working In The App

The active browser app is an Xcode project, not a SwiftPM package.

Open the vendored project with:

```bash
./Support/open_nook_project.sh
```

Or directly:

```bash
open Nook.xcodeproj
```

## Validation Notes

- The patched Swift files were syntax-checked successfully with `swiftc -parse`.
- Full `xcodebuild` validation is currently blocked on this machine because the installed Xcode toolchain is missing a required Apple private framework and fails before project compilation begins.

## Licensing

This repo root now carries Nook’s upstream `GPL-3.0` base. If this remains the product base, distribution and derivative-work obligations need to be handled accordingly.
