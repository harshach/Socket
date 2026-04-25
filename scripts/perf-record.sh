#!/usr/bin/env bash
#
# Record a short xctrace performance capture against the running Socket
# process and write the trace + a quick summary into .context/attachments/.
#
# Usage:
#   scripts/perf-record.sh                # 25s recording
#   scripts/perf-record.sh 40             # 40s recording
#   scripts/perf-record.sh 25 cnn-test    # custom suffix in filename
#
# The script:
#   1. Verifies Socket is running
#   2. Records the CPU Profiler template (CPU samples + signpost capture)
#   3. Writes .trace to .context/attachments/socket-perf-<ts>[-suffix].trace
#   4. Dumps the trace TOC + Points-of-Interest signpost intervals as XML
#      next to it for quick inspection without opening Instruments
#
# After it finishes, hand the .trace file (or the .signposts.xml) to
# Claude in the chat so it can read the actual interval timings.

set -euo pipefail

DURATION="${1:-25}"
SUFFIX="${2:-}"

if ! pgrep -x Socket >/dev/null; then
  echo "❌ Socket is not running. Launch the Debug build first." >&2
  echo "   open build/Build/Products/Debug/Socket.app" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
NAME="socket-perf-${TS}${SUFFIX:+-$SUFFIX}"
OUTDIR=".context/attachments"
TRACE="$OUTDIR/$NAME.trace"
TOC="$OUTDIR/$NAME.toc.xml"
SIGNPOSTS="$OUTDIR/$NAME.signposts.xml"

mkdir -p "$OUTDIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Recording $DURATION seconds → $TRACE"
echo "  ⚠️  Do your slow workflow NOW — open the tab, load the page."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

xcrun xctrace record \
  --template "CPU Profiler" \
  --attach Socket \
  --time-limit "${DURATION}s" \
  --output "$TRACE" \
  --quiet

echo
echo "✅ Trace captured: $TRACE"
echo "  Extracting table of contents…"
xcrun xctrace export --input "$TRACE" --toc --output "$TOC"

# Find the signpost intervals table schema and dump it. The schema name
# for OSSignposter-emitted intervals is typically "os-signpost-intervals"
# but can vary by macOS version, so we grep the TOC for whatever's there.
SCHEMA="$(grep -oE 'schema="[^"]*signpost[^"]*"' "$TOC" | head -1 | sed 's/schema="//;s/"//')"
if [[ -n "$SCHEMA" ]]; then
  echo "  Extracting signpost intervals (schema: $SCHEMA) → $SIGNPOSTS"
  xcrun xctrace export \
    --input "$TRACE" \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$SCHEMA\"]" \
    --output "$SIGNPOSTS"
else
  echo "  ⚠️  No signpost table found in TOC — Points of Interest may be empty."
  echo "  Open $TRACE in Instruments to inspect manually."
fi

echo
echo "Done. Files:"
ls -lh "$OUTDIR/$NAME"* | awk '{print "  " $9 "  " $5}'
echo
echo "Next: paste $SIGNPOSTS contents (or the file path) into chat."
