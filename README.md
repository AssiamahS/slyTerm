<p align="center">
  <img src="assets/icon.png" width="200" alt="slyTerm">
</p>

<h1 align="center">slyTerm</h1>

<p align="center">
  <strong>A lightweight native macOS terminal with split panes. Zero Electron.</strong>
</p>

<p align="center">
  <a href="https://github.com/AssiamahS/slyTerm/releases/latest">
    <img src="https://img.shields.io/badge/%E2%80%8E%20Download_on_the-Mac_App_Store-black?style=for-the-badge&logo=apple&logoColor=white" alt="Download on the Mac App Store">
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-orange?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/github/v/release/AssiamahS/slyTerm?style=flat-square" alt="Release">
  <img src="https://img.shields.io/github/license/AssiamahS/slyTerm?style=flat-square" alt="License">
</p>

---

## Features

- Native macOS app (Swift + WebKit) — no Electron, no Chrome
- Split pane terminal — up to 4 panes per window in a 2x2 grid
- Multiple windows
- Lightweight — single binary, ~200KB
- Built on ttyd for fast, GPU-accelerated terminal rendering

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | New window |
| `Cmd+T` | New split pane |
| `Cmd+W` | Close active split / window |
| `Cmd+Q` | Quit |
| `Ctrl+Cmd+F` | Full screen |
| `Cmd+M` | Minimize |
| `Cmd+C/V` | Copy / Paste |

## Install

### Quick Install (recommended)

```bash
git clone https://github.com/AssiamahS/slyTerm.git
cd slyTerm
chmod +x install.sh
./install.sh
```

The installer will:
1. Check for (and optionally install) ttyd via Homebrew
2. Build slyTerm from source
3. Install to `/Applications`
4. Optionally set up ttyd as a LaunchAgent

### Download DMG

Grab the latest `.dmg` from [Releases](https://github.com/AssiamahS/slyTerm/releases) and drag slyTerm to Applications.

You'll still need ttyd running:
```bash
brew install ttyd
ttyd -W -p 7681 -i 127.0.0.1 /bin/zsh
```

### Build from source

```bash
./build.sh
# App is at build/slyTerm.app
```

## Requirements

- macOS 14.0+ (Sonoma or later)
- Apple Silicon (arm64)
- [ttyd](https://github.com/nickvdp/ttyd) — `brew install ttyd`

## How it works

slyTerm is a native Cocoa app that wraps ttyd's web terminal in a WebKit view. Each pane connects to `localhost:7681` where ttyd serves an interactive shell. This gives you:

- Native macOS window management
- Hardware-accelerated rendering via WebKit
- Real terminal emulation (xterm.js under the hood)
- Zero overhead compared to browser-based terminals

## License

MIT
