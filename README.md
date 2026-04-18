# Socket update feeds

This directory is copied to the `gh-pages` branch on first run of the nightly or stable release workflow. It seeds:

- `appcast.xml` — stable channel, updated by `.github/workflows/macos-notarize.yml`
- `appcast-nightly.xml` — nightly channel, updated by `.github/workflows/nightly.yml`
- `index.html` — landing page at https://harshach.github.io/Socket/

Do not edit these files directly on `gh-pages` — both workflows will overwrite missing entries from this seed directory.

## First install

Socket is ad-hoc signed, not notarized. On first launch macOS Gatekeeper will refuse to open it. Workarounds:

1. **Right-click → Open** on `Socket.app`, confirm the prompt. One-time.
2. Or run in Terminal before launching: `xattr -dr com.apple.quarantine /Applications/Socket.app`

Subsequent launches and auto-updates go through Sparkle's EdDSA-signed appcast and don't need either workaround.

## Why not notarized?

We don't require an Apple Developer Program membership. Update integrity is verified via Sparkle's EdDSA signatures (`SUPublicEDKey` in the app's Info.plist). If the private key is compromised, every installed copy's updates are compromised — keep it out of git and never share it.
