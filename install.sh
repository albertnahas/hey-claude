#!/bin/bash
# Install Hey Claude: build from source, sign locally, install to ~/Applications, launch.
#   curl -fsSL https://raw.githubusercontent.com/albertnahas/hey-claude/main/install.sh | bash
# Or, from a clone: ./install.sh
set -euo pipefail

missing=()
xcrun --find swiftc >/dev/null 2>&1 || missing+=("Xcode Command Line Tools: run xcode-select --install")
command -v claude >/dev/null || missing+=("Claude Code: https://docs.anthropic.com/en/docs/claude-code")
if ((${#missing[@]})); then
  printf 'Hey Claude needs:\n'; printf '  - %s\n' "${missing[@]}"; exit 1
fi

# Run from a clone, or fetch the source when piped from curl.
src=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)
if [[ ! -f $src/Sources/HeyClaude.swift ]]; then
  src=$(mktemp -d)
  trap 'rm -rf "$src"' EXIT
  git clone --quiet --depth 1 https://github.com/albertnahas/hey-claude.git "$src"
fi
cd "$src"

app="$HOME/Applications/Hey Claude.app"
build="$src/build/HeyClaude.app"
rm -rf "$src/build" && mkdir -p "$build/Contents/MacOS" "$build/Contents/Resources"
swiftc -O -swift-version 5 Sources/HeyClaude.swift -o "$build/Contents/MacOS/HeyClaude"
cp Resources/Info.plist "$build/Contents/"
cp Resources/config.env Resources/AppIcon.icns "$build/Contents/Resources/"
install -m 755 Resources/hey-claude.sh "$build/Contents/Resources/"
# Your shell's PATH (minus temporary dirs), so the app finds claude, tmux and node
# wherever you installed them.
printf 'PATH=%q\n' "$(tr ':' '\n' <<<"$PATH" | grep -v -e '^/var/folders/' -e '^/private/' | paste -sd: -)" \
  >"$build/Contents/Resources/path.env"
# A stable local signing identity, so macOS keeps the app's permissions across updates
# (an ad-hoc signature changes with every build). Self-signed, stays in your login keychain.
identity="Hey Claude Local Signing"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
  keys=$(mktemp -d)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$identity" \
    -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$keys/key.pem" -out "$keys/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$keys/key.pem" -in "$keys/cert.pem" \
    -out "$keys/id.p12" -passout pass:heyclaude
  security import "$keys/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P heyclaude -T /usr/bin/codesign >/dev/null
  rm -rf "$keys"
fi
codesign --force --sign "$identity" --identifier com.albertnahas.heyclaude "$build"

pkill -x HeyClaude || true
mkdir -p "$HOME/Applications"
rm -rf "$app" && cp -R "$build" "$app"
open "$app"
command -v tmux >/dev/null ||
  echo "Tip: install tmux (brew install tmux) to keep sessions running after you close the window."
echo "Installed $app. Allow the permissions macOS asks for, then say \"Hey Claude\"."
