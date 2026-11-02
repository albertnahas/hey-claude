# Hey Claude

Say **"Hey Claude"** or **"Hello Claude"** anywhere on your Mac. Hey Claude takes a screenshot
of your whole desktop and starts a new [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
session in tmux with the screenshot as its first message, already sent. A terminal window
attached to that session opens, so you can keep talking to Claude about what's on your screen.

Wake-word detection runs entirely on your Mac using Apple's on-device speech recognizer.
No audio leaves the machine.

> Community project. Not affiliated with or endorsed by Anthropic.

## How it works

```
mic ─▶ on-device speech recognizer ─▶ "hey/hello claude"? ─▶ hey-claude.sh
                                                               ├─ screencapture (every display)
                                                               ├─ tmux new-session … claude "<prompt + screenshot path>"
                                                               └─ open a terminal attached to it
```

- `Sources/HeyClaude.swift`: the menu-bar app (listener, on/off toggle, settings window).
- `Resources/hey-claude.sh`: what happens on wake. Plain bash, easy to change.
- `Resources/config.env`: default settings, copied to `~/.config/hey-claude/config.env` on first launch.

## Requirements

| Dependency | Why | Install |
|---|---|---|
| macOS 14 Sonoma or later | on-device speech recognition, login-item and SwiftUI APIs | |
| Xcode Command Line Tools | `swiftc` and `codesign` to build the app | `xcode-select --install` |
| [tmux](https://github.com/tmux/tmux) | hosts the Claude Code session | `brew install tmux` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | the `claude` CLI, signed in | see the Claude Code docs |
| A terminal: Terminal (built in), [iTerm2](https://iterm2.com) or [cmux](https://cmux.dev) | shows the session | optional, Terminal is the default |

There are no third-party Swift packages. The app uses only Apple frameworks: Speech,
AVFoundation, AppKit, SwiftUI and ServiceManagement.

## Install

```bash
git clone https://github.com/albertnahas/hey-claude.git
cd hey-claude
./build.sh
```

This builds the app, signs it locally (ad hoc), installs it to `~/Applications/Hey Claude.app`
and launches it. On first launch, macOS asks for three permissions. Allow all three:

- **Speech Recognition** and **Microphone**, to hear the wake phrase.
- **Screen Recording**, to take the screenshot. If no prompt appears, enable *Hey Claude* in
  System Settings → Privacy & Security → Screen & System Audio Recording.

The app also registers itself to open at login. You can turn that off in its settings.

> Rebuilding changes the app's signature, so macOS asks for the permissions again. If a
> screenshot fails after a rebuild, remove *Hey Claude* from Screen Recording and add it back.

## Use it

- Say "Hey Claude" or "Hello Claude". You hear a chime, and the session opens.
- **On/off**: the waveform icon in the menu bar → *Settings…*. A slashed icon means it isn't
  listening, and the orange microphone dot goes away.
- **Can't see the icon?** On a crowded menu bar, macOS hides icons behind the notch. Open
  *Hey Claude* again from Spotlight to bring up its settings window.

## Configure

Settings → *Edit configuration…* opens `~/.config/hey-claude/config.env`:

| Key | Default | Meaning |
|---|---|---|
| `WAKE_PATTERN` | `\b(hey\|hello)\W+(claude\|claud\|clawed\|cloud\|clyde)\b` | Regex matched against what the Mac hears |
| `WORKDIR` | `$HOME` | Folder Claude Code starts in. Use one you have already trusted in Claude Code. |
| `CLAUDE_ARGS` | *(empty)* | Extra `claude` flags, e.g. `--model opus` |
| `PROMPT` | "Here is a screenshot…" | First message. `{screenshots}` becomes the image path(s). |
| `TERMINAL_APP` | `terminal` | `terminal`, `iterm` or `cmux`. For cmux, set its socket mode to Password and save a password (Settings → Automation, or `automation.socketControlMode` + `automation.socketPassword` in `cmux.json`). By default cmux only accepts commands from programs started inside it. |
| `KEEP_SCREENSHOTS_DAYS` | `7` | Older screenshots in `~/.hey-claude/shots` are deleted |

Changes apply on the next wake. A new `WAKE_PATTERN` is picked up within a minute.

## Privacy

- The wake phrase is detected on-device. Nothing is recorded or stored.
- Screenshots are saved to `~/.hey-claude/shots` and sent to Claude as part of the session,
  under your Claude Code account's data terms. Whatever is on screen goes with them, so
  switch Hey Claude off when sensitive information is showing.
- The log at `~/Library/Logs/HeyClaude.log` records detections and errors, never what you say.

## Troubleshooting

Settings → *Show log*. Every wake writes a `wake:` line, followed by `hey-claude.sh exited 0`.
If something fails, the script's error appears right above that line, and a notification tells
you to check the log.

## Uninstall

```bash
pkill -x HeyClaude
rm -rf ~/Applications/"Hey Claude.app" ~/.config/hey-claude ~/.hey-claude ~/Library/Logs/HeyClaude.log
defaults delete com.albertnahas.heyclaude
```

## License

[MIT](LICENSE)
