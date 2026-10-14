<p align="center">
  <img src="docs/banner.png" width="900" alt="Welcome to Tartelette: create your first virtual machine from macOS Tahoe, macOS Sequoia with Xcode or Ubuntu, from an IPSW, as an empty Linux VM or by importing one">
</p>

# Tartelette

[Español](README.md) · **English**

[![Latest release](https://img.shields.io/github/v/release/lacrimae0rerum/tartelette)](https://github.com/lacrimae0rerum/tartelette/releases/latest)
[![CI](https://github.com/lacrimae0rerum/tartelette/actions/workflows/ci.yml/badge.svg)](https://github.com/lacrimae0rerum/tartelette/actions/workflows/ci.yml)
![macOS 14+ · Apple silicon](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-000000?logo=apple)
[![License: MIT](https://img.shields.io/github/license/lacrimae0rerum/tartelette)](LICENSE)

A native macOS companion app for [Tart](https://tart.run): create, run, configure, share and
monitor Tart virtual machines without the terminal — with live performance metrics and a
clipboard that really works in both directions (text, rich text, images and files).

Tartelette drives the `tart` executable you already have installed (or the one it installs for you
when you ask), so everything it does is exactly what the CLI does. Every sheet shows the equivalent `tart …` command, ready to copy.

![The Tartelette dashboard: the welcome card with images ready to download and this Mac's live metrics](docs/screenshots/dashboard-welcome.png)

## Requirements

| | Requirement | Details |
|---|---|---|
| **Mac** | Apple silicon (M1 or later) | Intel Macs aren't supported: Tart only runs on Apple silicon and the app ships for `arm64` only (on an Intel Mac, macOS says it isn't supported on this type of Mac). |
| **macOS** | macOS 14 Sonoma or later | Tested on macOS 26.7 (Tahoe) and macOS 14.8 (Sonoma). On macOS 14, Tart can't be installed with Homebrew: install it from Tartelette or from its official download (see [Install Tart](#1-install-tart)), and Softnet networking isn't available. |
| **Tart** | 2.27 or later | The clipboard bridge, the console and guest metrics use `tart exec`, added in Tart 2.27.0. Tested with Tart 2.40.1. |
| **Virtual machines** | macOS and Linux (`arm64`) | Apple allows at most two macOS VMs running at a time. |
| **Inside the VM** | Tart Guest Agent | Needed for the clipboard, the console, guest metrics and the [AI agent](#ai-agents-mcp) tools. Preinstalled in the Cirrus Labs `*-base`, `*-xcode` and Linux images. On macOS, the clipboard also needs a logged-in user; on Linux, a desktop with `wl-clipboard` or `xclip`/`xsel`. |
| **Building** (optional) | Xcode 26 or later | Only if you build it yourself: see [Build from source](#build-from-source). |

## Install

### 1. Install Tart

**The easiest way is to let Tartelette install it.** If you don't have Tart, go on to steps 2 and
3: when you open Tartelette, you'll see **Tart Isn't Installed** with an **Install Tart** button.
Tartelette downloads the official Tart release from GitHub (about 23 MB), checks its SHA-256 and
that it's signed by Tart's developer (Cirrus Labs, team `9M2P8L4D89`), and keeps it, unmodified,
in `~/Library/Application Support/Tartelette/Tart`. It doesn't need Homebrew, so it also serves
macOS 14: it installs the same official download as the manual route. If anything fails, nothing
is installed. To update it, see
[Keep Tart up to date](#keep-tart-up-to-date).

**With [Homebrew](https://brew.sh)** (macOS 15 or later):

```bash
brew trust --formula openai/tools/tart openai/tools/softnet
brew install openai/tools/tart
```

Since Homebrew 6, formulae from third-party taps must be trusted before they can be installed,
and Tart depends on Softnet from the same tap. With just `brew install openai/tools/tart` the
install stops with "Refusing to load formula openai/tools/softnet from untrusted tap".

If you already have Tart from Homebrew, Tartelette keeps using it, and **Check for Updates** shows
`brew upgrade openai/tools/tart` when there's a newer release.

**By hand on macOS 14 Sonoma**: the Homebrew formula can't be installed (Softnet needs
macOS 15). If you'd rather not use Tartelette's install, install Tart from its official download:

```bash
curl -fL https://github.com/openai/tart/releases/latest/download/tart.tar.gz | tar -xz -C /Applications
```

Tartelette finds it in `/Applications/tart.app`. The **Tart Isn't Installed** screen also shows
the alternative for your macOS version (Homebrew or the official download), with a button to run
it in Terminal.

**Softnet** (for `--net-softnet` networking) isn't managed by Tartelette: Homebrew installs it with
Tart; if you use Tartelette's copy, install it with `brew install openai/tools/softnet` (macOS 15
or later).

### 2. Download and install Tartelette

1. Download **`Tartelette-1.0.0.dmg`** from the [latest release](https://github.com/lacrimae0rerum/tartelette/releases/latest).
2. Open it and drag **Tartelette** to the **Applications** folder. Always open it from
   Applications, not from the disk image.

The release also has `Tartelette-1.0.0.zip` (the same app) and `SHA256SUMS.txt` to
[verify the download](#verify-the-download).

### 3. Open it for the first time

Tartelette is **not notarized by Apple**. Notarization requires signing the app with a Developer
ID from the (paid) Apple Developer Program; this app is published with a local ("ad hoc")
signature and the hardened runtime enabled. That's why macOS blocks the first launch of a copy
downloaded with a browser. It's expected, and you only do this once:

1. Open **Tartelette** from Applications. macOS says it can't verify it ("Apple could not verify
   “Tartelette” is free of malware…"; on macOS 14, "“Tartelette” cannot be opened because it is
   from an unidentified developer"): dismiss the alert.
2. Go to **System Settings › Privacy & Security**, scroll down to the **Security** section and click
   **Open Anyway** next to the message about Tartelette. The button shows up for about an hour
   after you tried to open the app.
3. Confirm with **Open Anyway** and your login password. From then on it opens normally.

On macOS 14 you can also Control-click the app and choose **Open**.

If macOS says the app **"is damaged"** and won't let you open it, or you prefer the Terminal,
remove the quarantine flag your browser added to the download:

```bash
xattr -dr com.apple.quarantine /Applications/Tartelette.app
```

Also do this step if you'll use [AI agents](#ai-agents-mcp) with a downloaded copy: while
`tartelette-mcp` carries the flag, macOS kills it when it's launched. Only do this for copies downloaded from this repository,
ideally after
[verifying the download](#verify-the-download). To skip this step altogether, either
[install from the Terminal](#install-from-the-terminal) (files downloaded with `curl` aren't
quarantined) or [build it yourself](#build-from-source) (what you build on your Mac never is).

### Install from the Terminal

```bash
cd ~/Downloads
curl -fLO https://github.com/lacrimae0rerum/tartelette/releases/download/v1.0.0/Tartelette-1.0.0.zip
curl -fLO https://github.com/lacrimae0rerum/tartelette/releases/download/v1.0.0/SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt --ignore-missing   # should print: Tartelette-1.0.0.zip: OK

# If you have an older version, quit it first: this replaces it.
rm -rf /Applications/Tartelette.app
ditto -x -k Tartelette-1.0.0.zip /Applications
open /Applications/Tartelette.app
```

### Verify the download

Download `SHA256SUMS.txt` to the same folder too, then run:

```bash
cd ~/Downloads && shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Every file you downloaded must be listed with `OK`.

### Update

Download the new version and replace the app in Applications (or repeat
[the Terminal install](#install-from-the-terminal) with the new version). Settings, run profiles
and saved passwords are kept. Because every downloaded version is a new copy without a Developer
ID, macOS asks for the [first-launch step](#3-open-it-for-the-first-time) again and, if you saved
passwords in Tartelette, may ask once to let the new version read them from the Keychain.

### Keep Tart up to date

Tartelette never looks for new versions by itself: press **Check for Updates** in
**Settings › General › Tart** whenever you want to check (if you don't, you won't know there's a
new version). Updating Tart doesn't need a new version of Tartelette. What it offers depends on
where the Tart it uses comes from, as the **Source** row shows:

| Source | What it offers when there's a newer release |
|--------|---------------------------------------------|
| **Managed by Tartelette** | **Update to X**: downloads and verifies the new version and installs it next to the old one. Running VMs keep the version they started with; new commands use the new one. |
| **Homebrew** | The `brew upgrade openai/tools/tart` command, with a button to run it in Terminal, or **Install Managed Copy** (**Use Managed Copy** if you already have it) so Tartelette switches to its own copy. |
| **Other** or **Chosen in Settings** | **Install Tart X**: installs the managed copy and switches to it. |

When Tartelette manages a copy, **Settings › General** also shows the **Managed Copy** section:

- **Go Back to X** returns to the previous version, which Tartelette keeps. Older ones are only
  deleted when no process uses them.
- **Remove Managed Copy…** deletes the managed copy. Your VMs and images aren't affected, and
  Tartelette switches to another installed Tart, if there is one. It isn't possible while a VM or
  a `tart` command is using that copy.
- To use that copy in your own Terminal (for example, to paste the `tart …` commands the sheets
  show), the section shows the line that puts it first on your `PATH`. Run it or add it to
  `~/.zshrc`:

  ```bash
  export PATH="$HOME/Library/Application Support/Tartelette/Tart/current/tart.app/Contents/MacOS:$PATH"
  ```

  Tartelette doesn't need that line: **Open Terminal** and **Open SSH Session** already put the
  app's Tart first on the `PATH` of the window they open, and `tartelette-mcp` (see
  [AI agents](#ai-agents-mcp)) uses the same Tart as the app.

The Tart that Tartelette downloads comes with its own license,
[FSL-1.1-ALv2](https://github.com/openai/tart/blob/main/LICENSE).

### Uninstall

1. If you turned on **Open at login** (in **Settings › General**), turn it off.
2. Quit Tartelette and move `/Applications/Tartelette.app` to the Trash.
3. Optionally, remove its data as well (including the copy of Tart that Tartelette manages, if you
   installed it):

   ```bash
   rm -rf ~/Library/Application\ Support/Tartelette ~/Library/Caches/Tartelette ~/Library/Logs/Tartelette
   defaults delete io.github.lacrimae0rerum.Tartelette
   # These only exist if you saved passwords in Tartelette:
   security delete-generic-password -s io.github.lacrimae0rerum.Tartelette.ssh
   security delete-generic-password -s io.github.lacrimae0rerum.Tartelette.registry
   ```

Your virtual machines and images live in `~/.tart` (or `TART_HOME`): they belong to Tart and
uninstalling Tartelette doesn't touch them.

## Quick start

1. Open **Tartelette**, press **⌘N**, pick *macOS Tahoe* (or *Ubuntu*) and click **Download & Create**.
2. Select the VM and press **⌘R**.
3. Copy something on your Mac — it's already on the VM's clipboard. The first time, macOS may ask
   whether Tartelette can read what you copy (see [Permissions](#permissions-macos-asks-for)).

## What you can do

| Area | In the app | Tart equivalent |
|------|------------|-----------------|
| Create | New VM from a Cirrus Labs image, macOS IPSW (latest/file/URL), empty Linux VM, `.tvm` import | `clone`, `create --from-ipsw`, `create --linux`, `import` |
| Run | Start in a window, headless, with VNC (Screen Sharing or built-in), in Recovery, or with any saved run options | `run` and all its flags |
| Control | Request shutdown (graceful: macOS guests are asked through the Tart Guest Agent, with `SIGUSR2` when it doesn't answer; Linux guests get `SIGUSR2`), power off, suspend, force quit, show the VM window | `exec`, `SIGUSR2`, `stop`, `suspend` |
| Configure | CPU, memory, display (pt/px, refit), grow or replace the disk, new MAC/serial | `set` |
| Run options | Network (shared, bridged, Softnet allow/block/expose, host-only), shared folders, extra disks (image, cached VM, NBD), root disk caching/sync, Rosetta, nested virtualization, serial console, audio/USB/clipboard/input devices, first-boot provisioning | `run --net-* --dir --disk --root-disk-opts --rosetta --nested --serial …` |
| Access | IP address (DHCP, ARP or guest agent), Terminal shell in the guest, SSH, one-shot console | `ip`, `exec -it`, `exec` |
| Share | Push to registries (labels, chunked uploads, multiple tags), pull, export `.tvm`, clone, rename, delete | `push`, `pull`, `export`, `clone`, `rename`, `delete` |
| Registries | Log in/out; see Keychain, Docker config and environment credentials | `login --password-stdin`, `logout` |
| Storage | TART_HOME usage, per-VM allocation, cache breakdown, prune by age/budget/GC | `prune` |
| Monitor | Host CPU, memory, pressure, swap, thermal state; per-VM CPU (guest vs Tart), memory, disk I/O and power; guest CPU, load, memory, disk and uptime | — |
| AI agents | Let the agents on your Mac (Claude Code, Codex, Cursor…) use the VMs you share: start them, run commands, copy files and clone disposable VMs. See [AI agents](#ai-agents-mcp) | — |

Everywhere else: menu bar extra with live VM states, Dock badge (running VMs), Dock menu, Dock
progress for downloads, notifications when long jobs finish, keyboard shortcuts for every action.
The **Help** menu links to this repository, the release notes and the issue tracker.

## Screenshots

**Dashboard** — this Mac's CPU, memory, swap and thermal state, every running VM with its live
CPU, memory and power, and how much space Tart's VMs and caches take.

![Dashboard with host metrics, a running VM card and the storage breakdown](docs/screenshots/dashboard.png)

**A running macOS VM** — live CPU, memory, disk and power, the guest agent status and, behind it,
the VM's own window.

![Tartelette showing a running macOS VM: live CPU, memory, disk and power, the guest agent status and the VM's own window behind it](docs/screenshots/vm-overview-macos.png)

**VM overview** — a headless Ubuntu VM: live tiles, its configuration, the IP address (resolved by
DHCP, ARP or the guest agent), the guest agent status and the host processes behind it
(`tart run` and the Virtualization service), with the exact command it was started with.

![Overview of a running Linux VM with metrics, details, network, guest agent and host processes](docs/screenshots/vm-overview-linux.png)

**Working inside the VM** — the macOS guest in Tart's window next to Tartelette. With live sync on
(the orange clipboard button), anything you copy on either side is ready to paste on the other.

![A macOS VM window in front of Tartelette, with Terminal open inside the guest](docs/screenshots/macos-vm-window.png)

## Copy and paste between Mac and VM

Tart's built-in clipboard sharing (SPICE) is text-only, and on macOS guests the agent can replace
rich content on your Mac with plain text. Tartelette adds its own **clipboard bridge**:

| | Tartelette Bridge | Tart (SPICE) |
|---|---|---|
| Content | Text, RTF, HTML, PNG/TIFF images, files and folders | Plain text |
| Direction | Both, live (or one-way, or manual) | Both |
| Needs | Tart Guest Agent (Cirrus Labs `*-base`, `*-xcode`, Linux images) | Guest agent / `spice-vdagent` |

How it works: Tartelette watches your Mac's pasteboard and polls the guest's through
`tart exec`, moves every payload with a SHA-256 check (falling back to verified 128 KiB chunks
when a transfer is corrupted — see tart#1347), and remembers what it wrote on each side so
nothing echoes back. Copied files are staged in the guest and placed on its pasteboard, so
**⌘V in Finder pastes them**. You can also drop files on a VM to copy them to its Desktop.

Pick the engine per VM in **Run Options › Clipboard & Address** (or **Change…** in the
**Clipboard & Files** tab): *Automatic* (bridge for macOS guests, SPICE for Linux), *Tartelette
Bridge*, *Tart (SPICE)* or *Off*. With the bridge, VMs start with `--no-clipboard` so the two
mechanisms never fight. Live sync turns on by itself when a VM starts; change that in
**Settings › Clipboard › Turn on live sync when a VM starts**.

Linux guests need a desktop session plus `wl-clipboard` or `xclip`/`xsel`; the Cirrus Labs
server images have no desktop, so the bridge reports clipboard as unavailable there (file
transfer, console and metrics still work).

**macOS permission to read the clipboard.** Since macOS 15.4, macOS can ask (or refuse) before an
app reads what you copied in other apps. Live sync reads the Mac's clipboard on every copy, so
allow Tartelette in **System Settings › Privacy & Security › Paste from Other Apps**. When macOS
is set to ask or deny, the VM's **Clipboard & Files** tab says so and offers an **Open Settings…**
button that takes you there.

Good to know:

- A change is synced once it has settled: half-written clipboards (an app still adding items)
  and file items their app hasn't handed over yet are retried instead of sent partially.
- For 10 seconds after a sync, a copy of *some* of the just-synced files counts as an echo and
  isn't sent back. Copy them again after that window if you meant it.
- Only one Tartelette runs at a time: launching a second copy quits it and brings the first one
  forward, so two copies never sync the same VM against each other.

## AI agents (MCP)

Tartelette includes `tartelette-mcp`, an [MCP](https://modelcontextprotocol.io) server that lets
the AI agents on your Mac (Claude Code, Codex, Cursor…) use the VMs you share with them: start
them, run commands inside, copy files and clone disposable VMs to work in. The agent launches the
server itself and talks to it over standard input and output: nothing listens on a network port,
and it works while Tartelette is closed.

It's **off by default**, and no VM is shared until you decide, one VM at a time.

If you want your agent to set itself up, point it to [`docs/AGENT_SETUP.md`](docs/AGENT_SETUP.md):
it checks the requirements, adds Tartelette and asks you for the steps only you can take.

### Set it up

1. In **Settings › Agents**, turn on **Let AI agents use Tartelette's VMs**.
2. In the **Configuration** tab of each VM you want to share, pick its level under **Agent Access**
   (the levels are explained in the next section).
3. Add Tartelette to your agent. **Settings › Agents** shows the same, with buttons to copy it.

   In Claude Code:

   ```bash
   claude mcp add tartelette -- /Applications/Tartelette.app/Contents/MacOS/tartelette-mcp
   ```

   In other MCP clients:

   ```json
   {
     "mcpServers": {
       "tartelette": {
         "command": "/Applications/Tartelette.app/Contents/MacOS/tartelette-mcp"
       }
     }
   }
   ```

**If you downloaded Tartelette with a browser**, also remove the quarantine flag from the whole
bundle. While `tartelette-mcp` carries that flag, macOS kills it as soon as the agent launches it,
and the agent reports that the server failed to start.

```bash
xattr -dr com.apple.quarantine /Applications/Tartelette.app
```

What you [install from the Terminal](#install-from-the-terminal) or
[build yourself](#build-from-source) doesn't carry that flag.

If you move Tartelette to another folder, set it up in your agent again. `tartelette-mcp --version`
and `tartelette-mcp --help` also work from Terminal.

### What an agent can do

| Access | The agent can |
|--------|---------------|
| **None** (default) | Nothing: the VM isn't in its list |
| **Read** | See the VM and its settings |
| **Operate** | See it, start and stop it, run commands in it and copy files in and out |
| **Template** | See it and clone disposable VMs from it, which the agent then fully controls (including deleting them) |

Agents can only delete VMs they created; a VM later recreated under the same name isn't treated as
theirs. When something isn't allowed (agents are off, the VM isn't shared, the VM isn't theirs…),
the agent gets a message that explains why. On purpose, Tartelette doesn't offer the other
direction: an agent running inside a VM can't control the Mac.

### Tools and limits

| Tool | What it does |
|------|--------------|
| `list_vms` | Lists the shared VMs, with their state and access level |
| `vm_info` | Shows a VM's state and settings |
| `start_vm` | Starts a VM headless and, if asked, waits until the Tart Guest Agent answers |
| `stop_vm` | Asks the guest to shut down and powers it off if it doesn't in time; with `force`, powers it off at once |
| `create_sandbox` | Clones a stopped **Template** VM (generating a name when none is given) and can start it |
| `delete_vm` | Deletes a VM an agent created |
| `exec` | Runs a command in a login shell in the guest, with optional standard input and a timeout |
| `read_file` | Reads a guest file in pages, as text or base64 |
| `write_file` | Writes a file (text or base64), creates missing folders and verifies it with SHA-256 |

| Limit | Default |
|-------|---------|
| `exec` timeout | 120 s (up to 1800 s) |
| Output | 256 KiB for standard output and another 256 KiB for standard error in `exec`; 256 KiB per page in `read_file` |
| Files written by `write_file` | Up to 50 MiB |
| VMs created by agents | 4 at most |
| Running macOS VMs | 2 (Apple's limit) |

Agents reach the guest only through the Tart Guest Agent, preinstalled in the Cirrus Labs images
(Linux ones included); they don't use SSH.

**Known limitation.** Arguments that start with `data:` and contain a comma (for example, a file
whose content starts that way) are refused, because the MCP SDK would alter them. Send that
content base64-encoded.

Tested with Claude Code on macOS 26.7 and Tart 2.40.1, using the Cirrus Labs Ubuntu 24.04 image:
listing VMs, cloning a disposable VM from a **Template** VM, starting it (the guest agent answered
in about 5 seconds), running commands, writing and reading files, and stopping and deleting it.

### Log and settings

- **Log.** Every call is logged (time, agent client, tool, VM and outcome) in
  `~/Library/Logs/Tartelette/agents.log`. **Settings › Agents** shows the latest 50 and reveals
  the log with **Show Log in Finder**. Commands' standard input and file contents are never logged.
- **Settings.** They live in `~/Library/Application Support/Tartelette/agents.json` and apply
  immediately: agents see every change on their next call.
- **Damaged file.** If `agents.json` is damaged, Tartelette never overwrites it silently, and
  meanwhile agents can't use any VM.
  **Settings › Agents** offers to reset it with **Reset Agent Settings…**, which turns agents off
  and stops sharing every VM.

## Permissions macOS asks for

| When | What macOS asks | What to do |
|------|-----------------|------------|
| The first time you open a downloaded copy | Gatekeeper blocks it (the app isn't notarized) | [Open it for the first time](#3-open-it-for-the-first-time) |
| During live clipboard sync (macOS 15.4 or later) | Permission to read what you copy in other apps | **System Settings › Privacy & Security › Paste from Other Apps** → allow Tartelette |
| The first time you start a long job (create, clone, pull or push a VM…) | Permission to send notifications (they tell you when it finishes) | Optional; turn them off in **Settings › General › Notify when long operations finish** |
| When you enable Softnet | Your administrator password, once | **Settings › Registries & Network › Allow Softnet to Run…** |
| After an update, if you saved passwords | May ask for Keychain access | Allow it so the new version can read its passwords |

## Privacy

- **It only goes online when you ask.** Tartelette connects to GitHub (`api.github.com` and the
  Tart release download) only when you press **Check for Updates**, **Install** or **Update**.
  There's no telemetry, no analytics and no automatic update checks. All other network traffic
  comes from `tart` (pulling, pushing, registry login), from `ssh` to your VMs when that fallback
  is used, and from links you open in your browser.
- **The clipboard stays on your Mac.** It travels between your Mac and your local VMs through
  `tart exec` (or SSH). Transfers are staged in `~/Library/Caches/Tartelette/Clipboard`.
- **Passwords.** The password from **Registries › Log In** goes to `tart login --password-stdin`
  through standard input and Tartelette doesn't keep it (Tart does). The SSH fallback password and
  the optional credentials in **Settings › Registries & Network** are stored in the macOS
  Keychain; they reach `ssh` through an askpass helper and `tart` as `TART_REGISTRY_*` variables,
  never as command-line arguments.
- **AI agents, only if you turn them on.** `tartelette-mcp` talks to the agent that launches it
  only over standard input and output and doesn't listen on any network port (it includes the MCP
  SDK, which ships network transports it doesn't use). The call log never records commands'
  standard input or file contents.
- **Not sandboxed, on purpose.** The app has to run `tart`, read `~/.tart` and inspect VM
  processes to measure their usage — things the macOS sandbox doesn't allow.

## Build from source

You need an Apple silicon Mac and **Xcode 26 or later** (tested with Xcode 27.0), which itself
needs macOS 15.6 or later ([Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)).
The app you build runs on macOS 14 or later. The project uses build settings introduced in Xcode 26 (default `MainActor`
isolation and approachable concurrency) and an Icon Composer app icon (`.icon`), so older Xcode
versions can't build it. Continuous integration builds the app and runs every test with Xcode 26.0.1
and 26.6. The app has no third-party dependencies; the `tartelette-mcp` server uses the
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) and
[swift-log](https://github.com/apple/swift-log).

`xcodebuild` needs the full Xcode (the Command Line Tools alone aren't enough). If `make`
complains, select it:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

```bash
git clone https://github.com/lacrimae0rerum/tartelette.git
cd tartelette
make test       # TarteletteKit and app tests
make run        # Release build into build.noindex/Tartelette.app, then opens it
make install    # copies it to /Applications (pick another folder with INSTALL_DIR=…)
```

| Command | What it does |
|---------|--------------|
| `make test` | Runs the TarteletteKit (Swift Testing) and app test suites |
| `make build` | Release build, with `tartelette-mcp` inside, into `build.noindex/Tartelette.app` (the `.noindex` suffix keeps Spotlight from listing it next to the installed app) |
| `make run` | Builds and opens the app |
| `make install` | Builds and installs it into `/Applications`, swapping out the previous copy atomically (`INSTALL_DIR=…` for another folder) |
| `make uninstall` | Removes the installed app |
| `make package` | Creates `dist/Tartelette-<version>.dmg`, `.zip` and `SHA256SUMS.txt` from the Release build |
| `make release` | Everything a release needs, in order: `check-assets`, `test`, `package` |
| `make assets` | Regenerates the app icon, menu bar icons and brand mark |
| `make check-assets` | Checks that the committed brand assets match their renderer |
| `make open` | Opens the project in Xcode |
| `make clean` | Removes `build.noindex/`, `dist/` and the package's build cache |

What you build on your Mac is ad-hoc signed for `arm64` and isn't quarantined, so it opens
without the Gatekeeper step.

## How it's built

```
Tartelette.xcodeproj        app and tartelette-mcp targets (synchronized folder, local package dependency)
Tartelette/                 SwiftUI app: App/, Stores/, Features/, Components/, Support/
TarteletteTests/            app tests
TarteletteKit/              Swift package; only the MCP server has third-party dependencies
  TarteletteCore            domain: VM models, typed tart commands, parsers, ports
  TarteletteCLI             adapter: runs tart, streams progress, launches VMs, Keychain, Softnet
  TarteletteMetrics         adapter: host + per-VM process metrics, storage usage
  TarteletteGuest           adapter: tart exec/SSH transports, clipboard bridge, guest metrics
  TarteletteInstall         adapter: finds, downloads, verifies and installs the Tart the app manages (app only)
  TarteletteAgents          agent access: per-VM policy, agent VMs, authorization, audit log, tool logic
  TarteletteMCP             MCP server: exposes the agent tools (MCP Swift SDK)
  TarteletteMCPServer       the tartelette-mcp executable agents launch over stdio
Tools/BrandKit              code-drawn Liquid Glass app icon and menu bar icons
```

| Topic | Decision |
|-------|----------|
| Source of truth | The `tart` binary. Polling uses `tart list --format json` plus each VM's `config.json`, never `tart get` (it changes access dates used by `prune`). |
| Running VMs | `tart run` is spawned in its own session with output in `~/Library/Logs/Tartelette/<vm>.log`, so VMs keep running if the app quits. The running PID comes from Tart's `fcntl` lock on `config.json`, so VMs started from Terminal are controlled the same way. |
| Progress | Tart runs with `CI=1` (plain `N%` lines) and a PATH that includes Homebrew, so Softnet and Docker credential helpers are found. Cancelling sends `SIGINT`, which makes Tart clean up. |
| Per-VM metrics | Each VM runs in a `com.apple.Virtualization.VirtualMachine` XPC process; it's matched to its VM by the disk and NVRAM files it holds open. CPU time from `proc_pid_rusage` is converted from Mach ticks; power comes from the kernel's energy counter. |
| Secrets | The **Registries › Log In** password reaches Tart via stdin only and Tartelette never keeps it. SSH fallback passwords live in the Keychain and reach `ssh` through an askpass helper, never argv. |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| macOS won't open Tartelette, or says it "is damaged" | The app isn't notarized: follow [Open it for the first time](#3-open-it-for-the-first-time), or remove the quarantine flag with `xattr -dr com.apple.quarantine /Applications/Tartelette.app`. |
| The AI agent says the `tartelette-mcp` server failed to start | In a copy downloaded with a browser, macOS blocks it because of the quarantine flag: remove the flag from the whole bundle with `xattr -dr com.apple.quarantine /Applications/Tartelette.app`. If you moved Tartelette, set it up in the agent again (see [AI agents](#ai-agents-mcp)). |
| macOS says the app isn't supported on this type of Mac | It's an Intel Mac. Tart and Tartelette only run on Apple silicon. |
| macOS asks every time you copy something, or nothing goes from the Mac to the VM | Allow Tartelette in **System Settings › Privacy & Security › Paste from Other Apps** (the **Open Settings…** button in the **Clipboard & Files** tab takes you there). |
| "Tart isn't installed" | Press **Install Tart** (see [Install Tart](#1-install-tart)) or choose the binary with **Locate tart…** or in **Settings › General**. |
| `brew install openai/tools/tart` says "Refusing to load formula … from untrusted tap" | Homebrew 6 or later: run `brew trust --formula openai/tools/tart openai/tools/softnet` first. |
| Homebrew says "softnet: This formula does not run on macOS versions older than Sequoia" | You're on macOS 14: let Tartelette install Tart, or install it from its [official download](#1-install-tart). |
| "This copy of Tart failed the signature check…" | Tartelette doesn't use that copy and nothing was changed: Tart must be signed by its developer, Cirrus Labs (team `9M2P8L4D89`), and unmodified. Try again later; installing Tart again also replaces a damaged copy. |
| "Tartelette couldn't reach GitHub…", "…couldn't download Tart from GitHub" or "GitHub limits how often…" | You're offline, or GitHub's limit for requests without an account was reached. Nothing was installed: check your connection and try again (for the limit, when the message says). |
| "Tartelette is already installing or changing Tart…" | Another Tartelette operation on Tart is running (installing, updating, going back or removing the copy). Wait for it to finish, then try again. |
| Clipboard says the guest agent is unavailable | Use a `*-base`/`*-xcode` image, or install `tart-guest-agent` in the guest; make sure a user is logged in. |
| The AI agent says the VM's guest agent isn't answering | Agent tools reach the guest only through the Tart Guest Agent (not SSH): use a Cirrus Labs image, or install `tart-guest-agent` in the guest. If the VM just started, wait a few seconds (`start_vm` can wait until it answers). |
| Softnet networking fails | **Settings › Registries & Network › Allow Softnet to Run…** (one-time administrator prompt). |
| A third macOS VM won't start | Apple allows two macOS guests at a time. |
| Exec/agent features fail with a source-built Tart | Source builds report `SNAPSHOT`, which the macOS guest agent rejects; use a released Tart. |

Something else? [Open an issue](https://github.com/lacrimae0rerum/tartelette/issues) (or use
**Help › Report an Issue…** in the app).

## License

Tartelette is available under the [MIT License](LICENSE). Tart is a separate project with its
own license, [FSL-1.1-ALv2](https://github.com/openai/tart/blob/main/LICENSE); Tartelette contains
no Tart code and runs the `tart` you install, or the one it downloads from GitHub when you ask.
