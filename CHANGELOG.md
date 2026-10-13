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

### Changed

- **Build output**: `make` now builds into `build.noindex/` instead of `build/`. Spotlight
  doesn't index folders ending in `.noindex`, so local builds no longer appear as extra copies
  of Tartelette in app search. `make clean` also removes the old `build/` folder.

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
