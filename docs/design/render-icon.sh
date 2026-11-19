#!/usr/bin/env bash
# Renders icon-<look>.svg to a 1024 px PNG with Edge (Windows): render-icon.sh <look> <out.png>
here="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
"/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" --headless=new --disable-gpu --hide-scrollbars --window-size=1024,1024 \
  --screenshot="$2" "file:///${here// /%20}/icon-$1.svg"
