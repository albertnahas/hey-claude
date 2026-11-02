#!/bin/bash
# Build, ad-hoc sign and install Hey Claude to ~/Applications, then (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"

for dep in swiftc tmux claude; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep (see README)" >&2; exit 1; }
done

app="$HOME/Applications/Hey Claude.app"
build=build/HeyClaude.app

rm -rf build && mkdir -p "$build/Contents/MacOS" "$build/Contents/Resources"
swiftc -O -swift-version 5 Sources/HeyClaude.swift -o "$build/Contents/MacOS/HeyClaude"
cp Resources/Info.plist "$build/Contents/"
cp Resources/config.env "$build/Contents/Resources/"
install -m 755 Resources/hey-claude.sh "$build/Contents/Resources/"
codesign --force --sign - --identifier com.albertnahas.heyclaude "$build"

pkill -x HeyClaude || true
mkdir -p "$HOME/Applications"
rm -rf "$app" && cp -R "$build" "$app"
open "$app"
echo "Installed: $app"
