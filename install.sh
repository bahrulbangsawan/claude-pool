#!/bin/sh
# Installs the latest Claude Pool release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/bahrulbangsawan/claude-pool/main/install.sh | sh
set -eu

REPO="bahrulbangsawan/claude-pool"
APP="ClaudePool.app"
DEST="/Applications"

[ "$(uname -s)" = "Darwin" ] || { echo "Claude Pool runs on macOS only." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Claude Pool needs an Apple silicon Mac." >&2; exit 1; }

URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
	grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$URL" ] || { echo "Could not find a DMG in the latest release of $REPO." >&2; exit 1; }

TMP=$(mktemp -d)
MNT="$TMP/mnt"
cleanup() {
	hdiutil detach "$MNT" -quiet 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT

echo "Downloading $(basename "$URL")…"
curl -fL --progress-bar -o "$TMP/ClaudePool.dmg" "$URL"
hdiutil attach "$TMP/ClaudePool.dmg" -nobrowse -readonly -quiet -mountpoint "$MNT"

if pgrep -xq ClaudePool; then
	echo "Quitting the running Claude Pool…"
	osascript -e 'quit app "ClaudePool"' 2>/dev/null || pkill -x ClaudePool || true
	sleep 1
fi

echo "Installing to ${DEST}/${APP}…"
if [ -w "$DEST" ]; then
	rm -rf "$DEST/$APP"
	ditto "$MNT/$APP" "$DEST/$APP"
else
	sudo rm -rf "$DEST/$APP"
	sudo ditto "$MNT/$APP" "$DEST/$APP"
fi
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

# The claude-pool command: a link to the app, in the first of these folders that is on your PATH
# and writable. Anything else already named claude-pool is left alone.
CLI=""
for dir in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
	case ":$PATH:" in *":$dir:"*) ;; *) continue ;; esac
	[ -d "$dir" ] && [ -w "$dir" ] || continue
	link="$dir/claude-pool"
	target=$(readlink "$link" 2>/dev/null || true)
	if { [ ! -e "$link" ] && [ ! -L "$link" ]; } || [ "${target##*/}" = ClaudePool ]; then
		ln -sfn "$DEST/$APP/Contents/MacOS/ClaudePool" "$link" && CLI="$link"
	fi
	break
done

open "$DEST/$APP"
echo "Claude Pool is installed. Look for the crab in the menu bar."
if [ -n "$CLI" ]; then
	echo "Use your accounts from any terminal with claude-pool (claude-pool help)."
else
	echo "To use claude-pool in a terminal, add it in Claude Pool › Settings › Command Line Tool."
fi
