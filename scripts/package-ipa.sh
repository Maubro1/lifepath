#!/usr/bin/env bash
# Wraps an unsigned .app from an .xcarchive into an .ipa that SideStore can sign and install.
set -euo pipefail
archive="$1"; out="$2"
app="$archive/Products/Applications/LifePath.app"
[ -d "$app" ] || { echo "No app at $app" >&2; exit 1; }
tmp="$(mktemp -d)"
mkdir "$tmp/Payload"
cp -R "$app" "$tmp/Payload/"
out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
rm -f "$out_abs"
(cd "$tmp" && zip -qry "$out_abs" Payload)
rm -rf "$tmp"
