# Changelog

All notable changes to Tartelette are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **AI agents (MCP)**: `tartelette-mcp`, an MCP server embedded in the app, lets AI agents on the
  Mac (Claude Code, Codex, Cursor…) use the Tart VMs you share with them. Agents launch it over
  stdio, so nothing listens on a network port and it works while the app is closed. It's off by
  default: turn it on in **Settings › Agents**, then share each VM in its **Configuration** tab as
  Read, Operate or Template. Nine tools list and inspect VMs, start and stop them, clone
  disposable sandboxes from Template VMs, run commands and read or write files through the Tart
  Guest Agent. Agents can only delete VMs they created, calls have limits (timeouts, output and
  file sizes, number of agent VMs), and every call is logged to
  `~/Library/Logs/Tartelette/agents.log` and shown in Settings, never with command input or file
  contents.
- **Tart installed by Tartelette**: **Install Tart** on the "Tart Isn't Installed" screen
  downloads the latest official Tart release from GitHub (about 23 MB), checks its SHA-256 against
  the release's checksums file and that `tart.app` is signed by Tart's developer (Cirrus Labs,
  team `9M2P8L4D89`) and unmodified, and keeps it in `~/Library/Application Support/Tartelette/Tart`,
  with progress and Cancel. It doesn't need Homebrew, so it also works on macOS 14. Any failure
  installs nothing and leaves the previous state as it was. Homebrew stays fully supported.
- **Tart updates, only when you ask**: **Check for Updates** in **Settings › General › Tart** looks
  up the latest Tart release. The managed copy updates with **Update to X** (running VMs keep their
  version; new commands use the new one), goes back with **Go Back to X** and can be removed with
  **Remove Managed Copy…**, which leaves VMs and images alone. A Homebrew Tart keeps being used:
  the check shows `brew upgrade openai/tools/tart` and offers **Install Managed Copy**. Settings
  also shows the line that puts the managed Tart on your own `PATH` and links Tart's FSL-1.1-ALv2
  license. `tartelette-mcp` uses the same Tart as the app, including the managed copy.

### Changed

- **Build output**: `make` now builds into `build.noindex/` instead of `build/`. Spotlight
  doesn't index folders ending in `.noindex`, so local builds no longer appear as extra copies
  of Tartelette in app search. `make clean` also removes the old `build/` folder.
- **Privacy**: Tartelette now connects to GitHub, but only when you press **Check for Updates**,
  **Install** or **Update**. There's still no telemetry, analytics or automatic update check.

### Fixed

- **Terminal with the app's Tart**: **Open Terminal** and **Open SSH Session** put the directory of
  the Tart the app uses first on `PATH`, so `tart` in that window is the same Tart as the app's,
  even a copy that isn't on your `PATH`.
- **Softnet hints**: the messages shown when Softnet is missing now say
  `brew install openai/tools/softnet` instead of `brew install cirruslabs/cli/softnet`.

## [1.0.0] - 2026-10-09

First public release. Requires an Apple silicon Mac with macOS 14 Sonoma or later and Tart 2.27
or later.

### Added

- **Every Tart command in a GUI**: create (Cirrus Labs images, macOS IPSW, empty Linux VMs),
  clone, run with every `tart run` option (display and VNC modes, shared/bridged/Softnet/host-only
  networking, shared folders, extra disks, root disk options, Rosetta, nested virtualization,
  serial console, devices, first-boot provisioning), set, list, IP, exec, pull, push, login,
  logout, import, export, prune, rename, stop, suspend and delete. Each sheet shows the equivalent
  `tart …` command.
- **VM lifecycle**: VMs keep running when the app quits, graceful shutdown requests, and VMs
  started from Terminal are detected and controlled like the app's own.
- **Live metrics**: this Mac's CPU, memory, pressure, swap and thermal state; per-VM CPU (guest
  vs Tart), memory, disk I/O and power; guest CPU, load, memory, disk and uptime through the Tart
  Guest Agent.
- **Two-way clipboard bridge**: text, rich text (RTF/HTML), images and files or folders between
  the Mac and macOS or Linux guests, live or manual, with SHA-256-verified transfers and echo
  protection. Drop files on a VM to copy them to its Desktop.
- **Storage overview**: TART_HOME usage, per-VM allocation, cache breakdown and pruning.
- **Registries**: log in and out, and see which credentials Tart will use.
- **Mac integration**: Liquid Glass app icon, menu bar extra, Dock badge, menu and download
  progress, notifications for long jobs, keyboard shortcuts, open at login, and a single running
  copy at a time.
- **Tart setup help**: when Tart is missing, the app shows the install command that works on this
  Mac (Homebrew with formula trust on macOS 15 or later, Tart's release download on macOS 14) and
  can run it in Terminal.
- **Clipboard permission notice**: on macOS 15.4 or later, the **Clipboard & Files** tab explains
  when macOS asks before, or refuses, letting Tartelette read what you copy, with a shortcut to
  the setting.
- **Distribution**: drag-to-install disk image and zip with SHA-256 checksums, `make package` and
  `make release` targets, and continuous integration for builds and tests.

[Unreleased]: https://github.com/lacrimae0rerum/tartelette/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/lacrimae0rerum/tartelette/releases/tag/v1.0.0
