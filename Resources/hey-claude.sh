#!/bin/bash
# Screenshot every display, start Claude Code with the screenshot as its first (already-sent)
# message, and open it in a terminal window. Runs inside tmux when tmux is installed.
# Usage: hey-claude.sh <display-count> [question]   (macOS /bin/bash 3.2: no associative arrays)
set -euo pipefail
source "$(dirname "$0")/path.env"                    # PATH captured at install time
export PATH="$PATH:/usr/bin:/bin:/usr/sbin"
trap 'osascript -e "display notification \"Something went wrong. See ~/Library/Logs/HeyClaude.log\" with title \"Hey Claude\""' ERR

source "$(dirname "$0")/config.env"                  # defaults
config="$HOME/.config/hey-claude/config.env"
if [[ -f $config ]]; then source "$config"; fi       # user overrides

ts=$(date +%Y%m%d-%H%M%S)
data="$HOME/.hey-claude"
mkdir -p "$data/shots" "$data/sessions"
find "$data/shots" "$data/sessions" -type f -mtime +"$KEEP_SCREENSHOTS_DAYS" -delete

shots=()
for ((i = 1; i <= ${1:-1}; i++)); do shots+=("$data/shots/$ts-display$i.png"); done
screencapture -x "${shots[@]}"
afplay /System/Library/Sounds/Glass.aiff &

read -ra claude_args <<<"$CLAUDE_ARGS"
# env -u: a parent Claude Code session (or a tmux server started from one) leaks nesting markers.
question=${2:-}
if [[ -n $question ]]; then prompt=$PROMPT_WITH_QUESTION; else prompt=$PROMPT; fi
prompt=${prompt//\{screenshots\}/${shots[*]}}
prompt=${prompt//\{question\}/$question}
claude_cmd=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT
  claude ${claude_args[@]+"${claude_args[@]}"} "$prompt")

if command -v tmux >/dev/null; then
  session="hey-claude-$ts"
  tmux new-session -d -s "$session" -c "$WORKDIR" "${claude_cmd[@]}"
  run=(tmux attach -t "$session")
else
  run=("${claude_cmd[@]}")
fi

# One launcher script that every terminal can execute.
launcher="$data/sessions/$ts.command"
{
  echo '#!/bin/bash'
  printf 'export PATH=%q\ncd %q\nexec' "$PATH" "$WORKDIR"
  printf ' %q' "${run[@]}"
  echo
} >"$launcher"
chmod +x "$launcher"

# Supported terminals as key=bundle id, in fallback order.
terminals=(cmux=com.cmuxterm.app iterm=com.googlecode.iterm2 ghostty=com.mitchellh.ghostty
  wezterm=com.github.wez.wezterm kitty=net.kovidgoyal.kitty alacritty=org.alacritty
  terminal=com.apple.Terminal)
bundle_id() { printf '%s\n' "${terminals[@]}" | grep "^$1=" | cut -d= -f2; }
app_path() { mdfind "kMDItemCFBundleIdentifier == '$(bundle_id "$1")'" | head -1; }
is_running() { [[ -n $(lsappinfo find bundleID="$(bundle_id "$1")") ]]; }

launch() {
  case $1 in
    cmux)
      "$(app_path cmux)/Contents/Resources/bin/cmux" workspace create \
        --name "Hey Claude" --focus true --command "$launcher" && open -b com.cmuxterm.app ;;
    iterm)
      osascript -e 'on run argv' \
        -e 'tell application id "com.googlecode.iterm2" to create window with default profile command (item 1 of argv)' \
        -e 'tell application id "com.googlecode.iterm2" to activate' \
        -e 'end run' -- "$launcher" >/dev/null ;;
    ghostty) open -nb com.mitchellh.ghostty --args -e "$launcher" ;;
    wezterm) open -nb com.github.wez.wezterm --args start --always-new-process -- "$launcher" ;;
    kitty) open -nb net.kovidgoyal.kitty --args "$launcher" ;;
    alacritty) open -nb org.alacritty --args -e "$launcher" ;;
    terminal) open -b com.apple.Terminal "$launcher" ;;
  esac
}

# Try the configured terminal, then the ones already running, then any installed one.
keys=($(printf '%s\n' "${terminals[@]}" | cut -d= -f1))
order=()
if [[ $TERMINAL_APP != auto ]]; then order+=("$TERMINAL_APP"); fi
for t in "${keys[@]}"; do
  if is_running "$t"; then order+=("$t"); fi
done
order+=("${keys[@]}")

for t in "${order[@]}"; do
  [[ -n $(bundle_id "$t") && -n $(app_path "$t") ]] || continue
  if launch "$t"; then
    echo "opened in $t"
    exit 0
  fi
  echo "could not open $t, trying the next terminal" >&2
done
false  # no terminal worked: notify via the ERR trap
