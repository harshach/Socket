# Socket update feeds

This directory is copied to the `gh-pages` branch on first run of the nightly or stable release workflow so Sparkle clients can resolve the feed URL before any build has been published.

- `appcast.xml` — stable channel (updated by `.github/workflows/macos-notarize.yml`)
- `appcast-nightly.xml` — nightly channel (updated by `.github/workflows/nightly.yml`)
- `index.html` — landing page at https://harshach.github.io/Socket/

Do not edit these files directly on `gh-pages` — both workflows will overwrite missing entries from this seed directory.
