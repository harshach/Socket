#!/usr/bin/env python3
"""Insert a new Sparkle <item> into an appcast RSS file and cap to N entries.

Reads config from the environment so it can be called from both the nightly
and stable release workflows. Called once per build — idempotency is not a
requirement, but repeated runs should not produce duplicate adjacent entries.

Environment variables:
  APPCAST_PATH          Path to the appcast XML to update (required).
  APPCAST_TITLE         <title> text for the new <item>.
  APPCAST_PUBDATE       RFC 2822 date string.
  APPCAST_DMG_URL       Download URL.
  APPCAST_VERSION       Integer build number (sparkle:version).
  APPCAST_SHORT_VERSION Display version (sparkle:shortVersionString).
  APPCAST_DMG_SIZE      File size in bytes.
  APPCAST_RELEASE_NOTES Optional URL for <sparkle:releaseNotesLink>.
  APPCAST_MAX_ITEMS     Optional int; trim to N most recent items (default 50).
"""
from __future__ import annotations

import os
import re
import sys


def env(name: str, *, required: bool = True, default: str = "") -> str:
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"update-appcast: missing required env var {name}")
    return val


def main() -> None:
    path = env("APPCAST_PATH")
    title = env("APPCAST_TITLE")
    pubdate = env("APPCAST_PUBDATE")
    dmg_url = env("APPCAST_DMG_URL")
    version = env("APPCAST_VERSION")
    short_version = env("APPCAST_SHORT_VERSION")
    dmg_size = env("APPCAST_DMG_SIZE")
    notes_url = env("APPCAST_RELEASE_NOTES", required=False)
    max_items = int(env("APPCAST_MAX_ITEMS", required=False, default="50"))

    with open(path, encoding="utf-8") as f:
        content = f.read()

    notes_line = (
        f'      <sparkle:releaseNotesLink>{notes_url}</sparkle:releaseNotesLink>\n'
        if notes_url else ""
    )
    entry = (
        "    <item>\n"
        f"      <title>{title}</title>\n"
        f"{notes_line}"
        f"      <pubDate>{pubdate}</pubDate>\n"
        "      <enclosure\n"
        f'        url="{dmg_url}"\n'
        f'        sparkle:version="{version}"\n'
        f'        sparkle:shortVersionString="{short_version}"\n'
        f'        length="{dmg_size}"\n'
        '        type="application/octet-stream"/>\n'
        "    </item>\n"
    )

    if "</channel>" not in content:
        sys.exit(f"update-appcast: {path} has no </channel> tag — malformed seed?")

    # Insert the new entry as the FIRST <item>. Sparkle doesn't require any
    # particular order (it does version comparison), but newest-first is the
    # convention and makes the raw feed pleasant to read.
    if re.search(r"<item>", content):
        content = re.sub(r"[ \t]*<item>", entry + "    <item>", content, count=1)
    else:
        # Empty seed — insert just before </channel>.
        content = re.sub(r"[ \t]*</channel>", entry + "  </channel>", content, count=1)

    # Cap the feed so gh-pages doesn't grow unbounded. Items are newest-first,
    # so keep the first `max_items` and drop the rest.
    items = re.findall(r"<item>.*?</item>", content, flags=re.DOTALL)
    if len(items) > max_items:
        kept = items[:max_items]
        prefix = content.split("<item>", 1)[0].rstrip() + "\n    "
        joined = "\n    ".join(kept)
        content = f"{prefix}{joined}\n  </channel>\n</rss>\n"

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"update-appcast: wrote entry for {short_version} to {path}")


if __name__ == "__main__":
    main()
