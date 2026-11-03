# Hey Claude: voice wake word for Claude Code on macOS

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)](Sources/HeyClaude.swift)
[![On-device](https://img.shields.io/badge/speech-on--device-2ea44f)](#privacy)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Say "Hey Claude" anywhere on your Mac, and Claude sees your screen.** Hey Claude is a tiny,
hands-free menu-bar app that listens for a wake word. When it hears one, it takes a screenshot of
your whole desktop and opens a new [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
session with that screenshot already sent. Claude looks at your screen right away, and you keep
talking to it in a terminal window.

- 🎙️ **Voice activation, offline.** Uses Apple's on-device speech recognition. No audio leaves your Mac, and there's no API key or cloud wake-word service.
- 🖥️ **Screen-aware AI assistant.** Captures every display and hands the screenshot to Claude as the first message.
- 🧵 **A real Claude Code session.** With tmux installed, sessions keep running after you close the window, and you can reattach or keep several going.
- ⚙️ **Works with what you have.** Set your own wake phrases. Sessions open in the terminal you already use, with automatic fallbacks: cmux, iTerm2, Ghostty, WezTerm, kitty, Alacritty or Terminal.
- 🪶 **Tiny and native.** One Swift file, one bash script, Apple frameworks only.

> Community project. Not affiliated with or endorsed by Anthropic.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/albertnahas/hey-claude/main/install.sh | bash
```

The installer checks the [requirements](#requirements), builds the app from source on your Mac,
installs it to `~/Applications/Hey Claude.app` and launches it. Building locally means macOS
Gatekeeper never blocks a downloaded binary. Prefer to read the code first? Clone the repo and
run `./install.sh`.

On first launch, allow the three permissions macOS asks for:

| Permission | Why |
|---|---|
| Speech Recognition | Detect the wake phrase, on-device |
| Microphone | Hear it |
| Screen Recording | Take the screenshot. If no prompt appears, enable *Hey Claude* in System Settings → Privacy & Security → Screen & System Audio Recording. |

The installer signs the app with a self-signed *Hey Claude Local Signing* certificate that it
creates once in your login keychain. That keeps the permissions across updates. To update, run
the installer again.

## Requirements

| Dependency | Why | Install |
|---|---|---|
| macOS 14 Sonoma or later | on-device speech, SwiftUI and login-item APIs | |
| Xcode Command Line Tools | `swiftc` and `codesign` to build the app | `xcode-select --install` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | the `claude` CLI, signed in | see the Claude Code docs |
| [tmux](https://github.com/tmux/tmux) *(optional)* | keeps sessions alive after the window closes | `brew install tmux` |
| Any terminal | shows the session | Terminal is built in. Also supported: [cmux](https://cmux.dev), [iTerm2](https://iterm2.com), [Ghostty](https://ghostty.org), [WezTerm](https://wezterm.org), [kitty](https://sw.kovidgoyal.net/kitty/), [Alacritty](https://alacritty.org) |

There are no third-party packages. The app uses only Apple frameworks: Speech, AVFoundation,
AppKit, SwiftUI and ServiceManagement.

## Use it

1. Say **"Hey Claude"** or **"Hello Claude"**.
2. A chime confirms the screenshot, and a terminal window opens with Claude already looking at
   your screen.
3. Ask your question: *"what's wrong with this error?"*, *"summarise this page"*, *"reply to this
   email"*.

The waveform icon in the menu bar shows its state. A slashed icon means it isn't listening, and
macOS's orange microphone dot goes away with it.

## Settings

Open **Settings…** from the menu-bar icon. If your menu bar is crowded and the icon is hidden
behind the notch, open *Hey Claude* from Spotlight instead.

- **Listen for the wake phrase**: the on/off switch.
- **Wake phrases**: comma-separated, e.g. `Hey Claude, Hello Claude, OK Computer`. Press Return to
  apply. Phrases match whole words, case-insensitively, in your Mac's system language.
- **Open at login**
- **Edit session settings…**: opens `~/.config/hey-claude/config.env`:

| Key | Default | Meaning |
|---|---|---|
| `WORKDIR` | `~/.hey-claude` | Folder Claude Code starts in. Claude Code asks you to trust it on the first wake. |
| `CLAUDE_ARGS` | *(empty)* | Extra `claude` flags, e.g. `--model opus` |
| `PROMPT` | "Here is a screenshot…" | First message. `{screenshots}` becomes the image path(s). |
| `TERMINAL_APP` | `auto` | `auto` uses a terminal that's already open, then any installed one. Or name one: `cmux`, `iterm`, `ghostty`, `wezterm`, `kitty`, `alacritty`, `terminal`. If it fails, the others are tried in turn. |
| `KEEP_SCREENSHOTS_DAYS` | `7` | Older screenshots and session launchers in `~/.hey-claude` are deleted |

Session settings apply on the next wake, without restarting the app.

### cmux

By default, cmux only accepts commands from programs started inside it, so Hey Claude falls back
to your next terminal. To open sessions in cmux, set its socket mode to **Password** and save a
password: Settings → Automation, or set `automation.socketControlMode` and
`automation.socketPassword` in `~/.config/cmux/cmux.json`.

## How it works

```
mic ─▶ on-device speech recognizer ─▶ wake phrase? ─▶ hey-claude.sh
                                                        ├─ screencapture (every display)
                                                        ├─ claude "<prompt + screenshot paths>" (in tmux if installed)
                                                        └─ open it in your terminal, with fallbacks
```

- [`Sources/HeyClaude.swift`](Sources/HeyClaude.swift): the menu-bar app (listener, settings window).
- [`Resources/hey-claude.sh`](Resources/hey-claude.sh): what happens on wake. Plain bash, easy to change.
- [`Resources/config.env`](Resources/config.env): default session settings.

## Privacy

- Wake phrases are detected on-device. No audio is recorded or stored.
- Screenshots are saved to `~/.hey-claude/shots` and sent to Claude as part of the session,
  under your Claude Code account's data terms. Whatever is on screen goes with them, so switch
  Hey Claude off when sensitive information is showing.
- The log at `~/Library/Logs/HeyClaude.log` records detections and errors, never what you say.

## Troubleshooting

Use **Settings → Show log**. Every wake writes a `wake:` line, followed by
`hey-claude.sh exited 0`. If something fails, the error appears just above that line, and a
notification tells you to check the log.

| Symptom | Fix |
|---|---|
| `could not create image from display` | Screen Recording permission is missing or stale. Turn it off and on again. |
| `could not open cmux, trying the next terminal` | See [cmux](#cmux). |
| `claude: command not found` | Re-run the installer from a shell where `claude` works. It records your `PATH`. |
| Never triggers | Check the menu-bar icon isn't slashed, and that the log shows `listening`. Speak the phrase as its own sentence. |

## Uninstall

```bash
pkill -x HeyClaude
rm -rf ~/Applications/"Hey Claude.app" ~/.config/hey-claude ~/.hey-claude ~/Library/Logs/HeyClaude.log
defaults delete com.albertnahas.heyclaude
security delete-identity -c "Hey Claude Local Signing"
```

## License

[MIT](LICENSE)
