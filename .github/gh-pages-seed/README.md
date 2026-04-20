# Socket update feeds

This directory is copied to the `gh-pages` branch on first run of the nightly or stable release workflow. It seeds:

- `appcast.xml` — stable channel, updated by `.github/workflows/macos-notarize.yml`
- `appcast-nightly.xml` — nightly channel, updated by `.github/workflows/nightly.yml`
- `index.html` — landing page at https://harshach.github.io/Socket/

Do not edit these files directly on `gh-pages` — both workflows will overwrite missing entries from this seed directory.

## First install (macOS 15+)

Recommended — the one-liner installer. Because it runs via `curl | bash`, the script itself is never quarantined, so it can strip `com.apple.quarantine` / `com.apple.provenance` from the DMG before Gatekeeper ever sees `Socket.app`:

```sh
/bin/bash -c "$(curl -fsSL https://harshach.github.io/Socket/install.sh)"
```

Nightly channel:

```sh
SOCKET_CHANNEL=nightly /bin/bash -c "$(curl -fsSL https://harshach.github.io/Socket/install.sh)"
```

**Manual install fallback** — if someone downloads the DMG from the Releases page directly:

```sh
sudo xattr -cr /Applications/Socket.app
```

Then right-click → Open. (`-cr` clears every extended attribute. The narrower `xattr -dr com.apple.quarantine` doesn't work on macOS 15 because Gatekeeper also inspects `com.apple.provenance`.)

Subsequent auto-updates go through Sparkle's EdDSA-signed appcast and don't trip Gatekeeper again.

## Why not notarized?

We don't require an Apple Developer Program membership. Update integrity is verified via Sparkle's EdDSA signatures (`SUPublicEDKey` in the app's Info.plist). If the private key is compromised, every installed copy's updates are compromised — keep it out of git and never share it.
