#!/bin/bash
# Screenshot every display, start Claude Code in a detached tmux session with the
# screenshot as its first (already-sent) message, then open a window attached to it.
# Usage: hey-claude.sh <display-count>
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:$HOME/.local/bin"
trap 'osascript -e "display notification \"Something went wrong. See ~/Library/Logs/HeyClaude.log\" with title \"Hey Claude\""' ERR

source "$(dirname "$0")/config.env"                  # defaults
config="$HOME/.config/hey-claude/config.env"
if [[ -f $config ]]; then source "$config"; fi       # user overrides

ts=$(date +%Y%m%d-%H%M%S)
shots_dir="$HOME/.hey-claude/shots"
mkdir -p "$shots_dir"
find "$shots_dir" -name '*.png' -mtime +"$KEEP_SCREENSHOTS_DAYS" -delete

shots=()
for ((i = 1; i <= ${1:-1}; i++)); do shots+=("$shots_dir/$ts-display$i.png"); done
screencapture -x "${shots[@]}"
afplay /System/Library/Sounds/Glass.aiff &

session="hey-claude-$ts"
read -ra claude_args <<<"$CLAUDE_ARGS"
# env -u: a tmux server started from inside Claude Code would leak its nesting markers.
tmux new-session -d -s "$session" -c "$WORKDIR" \
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
  claude ${claude_args[@]+"${claude_args[@]}"} "${PROMPT//\{screenshots\}/${shots[*]}}"

attach="tmux attach -t $session"
case $TERMINAL_APP in
  cmux)
    /Applications/cmux.app/Contents/Resources/bin/cmux workspace create \
      --name "Hey Claude" --focus true --command "$attach"
    open -a cmux
    ;;
  iterm)
    osascript -e 'on run argv' \
      -e 'tell application "iTerm" to create window with default profile command (item 1 of argv)' \
      -e 'tell application "iTerm" to activate' \
      -e 'end run' -- "$attach"
    ;;
  *)
    osascript -e 'on run argv' \
      -e 'tell application "Terminal" to do script (item 1 of argv)' \
      -e 'tell application "Terminal" to activate' \
      -e 'end run' -- "$attach"
    ;;
esac
