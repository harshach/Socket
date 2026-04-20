#!/usr/bin/env python3
"""Unit tests for `.github/scripts/update-appcast.py`.

Run locally (from repo root):
    python3 -m unittest .github.scripts.test_update_appcast

In CI (`.github/workflows/test.yml`) this runs alongside the Swift XCTest
target so a broken appcast helper can't silently ship a bad release.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / ".github" / "scripts" / "update-appcast.py"
NIGHTLY_SEED = REPO_ROOT / ".github" / "gh-pages-seed" / "appcast-nightly.xml"
STABLE_SEED = REPO_ROOT / ".github" / "gh-pages-seed" / "appcast.xml"

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _run(path: Path, **env_overrides: str) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["APPCAST_PATH"] = str(path)
    env.update(env_overrides)
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


class UpdateAppcastTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="appcast-tests-"))
        self.feed = self.tmp / "feed.xml"
        shutil.copy(NIGHTLY_SEED, self.feed)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- Happy path ---------------------------------------------------------

    def test_insert_produces_wellformed_xml(self) -> None:
        res = _run(
            self.feed,
            APPCAST_TITLE="Nightly 1.2.3",
            APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
            APPCAST_DMG_URL="https://example.com/v1.dmg",
            APPCAST_VERSION="1",
            APPCAST_SHORT_VERSION="1.2.3",
            APPCAST_DMG_SIZE="100000",
        )
        self.assertEqual(res.returncode, 0, msg=f"stderr: {res.stderr}")

        tree = ET.parse(self.feed)
        items = tree.findall(".//item")
        self.assertEqual(len(items), 1)

        encl = items[0].find("enclosure")
        self.assertIsNotNone(encl)
        self.assertEqual(encl.get("url"), "https://example.com/v1.dmg")
        self.assertEqual(encl.get("length"), "100000")
        self.assertEqual(encl.get(f"{{{SPARKLE_NS}}}version"), "1")
        self.assertEqual(encl.get(f"{{{SPARKLE_NS}}}shortVersionString"), "1.2.3")
        self.assertIsNone(
            encl.get(f"{{{SPARKLE_NS}}}edSignature"),
            "Without APPCAST_ED_SIGNATURE, the attr must be omitted entirely.",
        )

    def test_ed_signature_lands_on_enclosure(self) -> None:
        res = _run(
            self.feed,
            APPCAST_TITLE="Nightly 1.2.3",
            APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
            APPCAST_DMG_URL="https://example.com/v1.dmg",
            APPCAST_VERSION="1",
            APPCAST_SHORT_VERSION="1.2.3",
            APPCAST_DMG_SIZE="100000",
            APPCAST_ED_SIGNATURE="d1ZBdRaWsignature==",
        )
        self.assertEqual(res.returncode, 0, msg=f"stderr: {res.stderr}")

        tree = ET.parse(self.feed)
        encl = tree.find(".//enclosure")
        self.assertIsNotNone(encl)
        self.assertEqual(
            encl.get(f"{{{SPARKLE_NS}}}edSignature"),
            "d1ZBdRaWsignature==",
            "EdDSA signature must surface as sparkle:edSignature on the enclosure or Sparkle clients with SUPublicEDKey reject the update.",
        )

    def test_release_notes_line_included_when_set(self) -> None:
        res = _run(
            self.feed,
            APPCAST_TITLE="v1.2.3",
            APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
            APPCAST_DMG_URL="https://example.com/v1.dmg",
            APPCAST_VERSION="1",
            APPCAST_SHORT_VERSION="1.2.3",
            APPCAST_DMG_SIZE="100000",
            APPCAST_RELEASE_NOTES="https://example.com/notes",
        )
        self.assertEqual(res.returncode, 0, msg=f"stderr: {res.stderr}")

        tree = ET.parse(self.feed)
        link = tree.find(f".//{{{SPARKLE_NS}}}releaseNotesLink")
        self.assertIsNotNone(link)
        self.assertEqual(link.text, "https://example.com/notes")

    # ---- Ordering + trimming -----------------------------------------------

    def test_newest_first_ordering(self) -> None:
        for i in range(1, 4):
            res = _run(
                self.feed,
                APPCAST_TITLE=f"Nightly 1.1.0-nightly.{i:03d}",
                APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
                APPCAST_DMG_URL=f"https://example.com/v{i}.dmg",
                APPCAST_VERSION=str(i),
                APPCAST_SHORT_VERSION=f"1.1.0-nightly.{i:03d}",
                APPCAST_DMG_SIZE="100000",
            )
            self.assertEqual(res.returncode, 0, msg=f"stderr: {res.stderr}")

        titles = [t.text for t in ET.parse(self.feed).findall(".//item/title")]
        self.assertEqual(
            titles,
            [
                "Nightly 1.1.0-nightly.003",
                "Nightly 1.1.0-nightly.002",
                "Nightly 1.1.0-nightly.001",
            ],
            "Newest entry must be first — Sparkle parses latest-first by convention and raw readability matters for debugging.",
        )

    def test_max_items_trim_keeps_newest(self) -> None:
        for i in range(1, 6):
            _run(
                self.feed,
                APPCAST_TITLE=f"v{i}",
                APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
                APPCAST_DMG_URL=f"https://example.com/v{i}.dmg",
                APPCAST_VERSION=str(i),
                APPCAST_SHORT_VERSION=f"1.0.{i}",
                APPCAST_DMG_SIZE="100000",
                APPCAST_MAX_ITEMS="3",
            )

        titles = [t.text for t in ET.parse(self.feed).findall(".//item/title")]
        self.assertEqual(
            titles,
            ["v5", "v4", "v3"],
            "Trimming must drop the oldest items, not the newest — we had this inverted on an earlier pass.",
        )

    # ---- Failure modes ------------------------------------------------------

    def test_missing_required_env_fails_with_clear_error(self) -> None:
        res = _run(
            self.feed,
            APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
            APPCAST_DMG_URL="https://example.com/v1.dmg",
            APPCAST_VERSION="1",
            APPCAST_SHORT_VERSION="1.2.3",
            APPCAST_DMG_SIZE="100000",
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("APPCAST_TITLE", res.stderr)

    def test_malformed_seed_without_channel_close_rejected(self) -> None:
        self.feed.write_text("<?xml version='1.0'?><rss><channel></rss>\n")
        res = _run(
            self.feed,
            APPCAST_TITLE="v1",
            APPCAST_PUBDATE="Sat, 18 Apr 2026 12:00:00 -0700",
            APPCAST_DMG_URL="https://example.com/v1.dmg",
            APPCAST_VERSION="1",
            APPCAST_SHORT_VERSION="1.0.0",
            APPCAST_DMG_SIZE="100000",
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("channel", res.stderr.lower())

    # ---- Seed files themselves are valid XML --------------------------------

    def test_seed_files_are_wellformed(self) -> None:
        for seed in (NIGHTLY_SEED, STABLE_SEED):
            tree = ET.parse(seed)
            self.assertIsNotNone(tree.find(".//channel"))


if __name__ == "__main__":
    unittest.main()
