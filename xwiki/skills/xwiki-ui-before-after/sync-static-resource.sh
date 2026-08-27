#!/usr/bin/env bash
# Copy a raw skin/webapp static resource (CSS/JS served straight from webapps/xwiki/resources,
# not packaged into a jar or xar) into a running instance, and keep any pre-built .min sibling in
# sync too - a stale .min.css/.min.js next to the raw file is served instead whenever a template
# loads it via $xwiki.get('ssfx').use('path/to/foo.css', true) (the trailing `true` prefers the
# minified sibling if one exists on disk). Overwriting only the raw file and restarting Jetty has
# zero visible effect if that stale sibling is what's actually served - this script closes that
# gap by refreshing both from the same source in one step.
#
# This is NOT for xar-packaged wiki pages (use setup-xar-instance.sh) or jar-packaged classes
# (use setup-instance.sh) - it's for plain static files that ship as-is inside a `war` module,
# e.g. xwiki-platform-web-war's resources/uicomponents/**.
#
# Usage:
#   sync-static-resource.sh <instance-dir> <source-file> <relative-path-under-resources>
#
# <instance-dir>                    path to a XWiki jetty+hsqldb distribution root.
# <source-file>                     the fixed/branch file to deploy, e.g.
#                                    xwiki-platform-core/.../resources/uicomponents/viewers/comments.css
# <relative-path-under-resources>   where it lives under webapps/xwiki/resources/, e.g.
#                                    uicomponents/viewers/comments.css
set -euo pipefail

INSTANCE_DIR="$1"
SOURCE_FILE="$2"
REL_PATH="$3"

TARGET_DIR="$INSTANCE_DIR/webapps/xwiki/resources/$(dirname "$REL_PATH")"
BASENAME="$(basename "$REL_PATH")"
EXT="${BASENAME##*.}"
STEM="${BASENAME%.*}"

if [ ! -d "$TARGET_DIR" ]; then
  echo "ERROR: $TARGET_DIR does not exist - check the relative path" >&2
  exit 1
fi

cp "$SOURCE_FILE" "$TARGET_DIR/$BASENAME"
echo "synced $TARGET_DIR/$BASENAME"

MIN_PATH="$TARGET_DIR/${STEM}.min.${EXT}"
if [ -f "$MIN_PATH" ]; then
  # Crude copy, not a real minification pass - fine for a visual repro, where the point is that
  # the SAME content is served regardless of which of the two files ssfx picks.
  cp "$SOURCE_FILE" "$MIN_PATH"
  echo "synced $MIN_PATH (pre-built minified sibling - kept in lockstep, not re-minified)"
fi
