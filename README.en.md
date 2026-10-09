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

Tartelette drives the `tart` executable you already have installed, so everything it does is
exactly what the CLI does. Every sheet shows the equivalent `tart …` command, ready to copy.

![The Tartelette dashboard: the welcome card with images ready to download and this Mac's live metrics](docs/screenshots/dashboard-welcome.png)

## Requirements

| | Requirement | Details |
|---|---|---|
| **Mac** | Apple silicon (M1 or later) | Intel Macs aren't supported: Tart only runs on Apple silicon and the app ships for `arm64` only (on an Intel Mac, macOS says it isn't supported on this type of Mac). |
| **macOS** | macOS 14 Sonoma or later | Tested on macOS 26.7 (Tahoe) and macOS 14.8 (Sonoma). On macOS 14, Tart is installed from its official download rather than Homebrew (see [Install Tart](#1-install-tart)), and Softnet networking isn't available. |
| **Tart** | 2.27 or later | The clipboard bridge, the console and guest metrics use `tart exec`, added in Tart 2.27.0. Tested with Tart 2.40.1. |
| **Virtual machines** | macOS and Linux (`arm64`) | Apple allows at most two macOS VMs running at a time. |
| **Inside the VM** | Tart Guest Agent | Needed for the clipboard, the console and guest metrics. Preinstalled in the Cirrus Labs `*-base`, `*-xcode` and Linux images. On macOS, the clipboard also needs a logged-in user; on Linux, a desktop with `wl-clipboard` or `xclip`/`xsel`. |
| **Building** (optional) | Xcode 26 or later | Only if you build it yourself: see [Build from source](#build-from-source). |

## Install

### 1. Install Tart

**macOS 15 or later**, with [Homebrew](https://brew.sh):

```bash
brew trust --formula openai/tools/tart openai/tools/softnet
brew install openai/tools/tart
```

Since Homebrew 6, formulae from third-party taps must be trusted before they can be installed,
and Tart depends on Softnet from the same tap. With just `brew install openai/tools/tart` the
install stops with "Refusing to load formula openai/tools/softnet from untrusted tap".

**macOS 14 Sonoma**: the Homebrew formula can't be installed (Softnet needs macOS 15), so install
Tart from its official download:

```bash
curl -fL https://github.com/openai/tart/releases/latest/download/tart.tar.gz | tar -xz -C /Applications
```

Tartelette finds it in `/Applications/tart.app`. If Tart is missing, the app itself shows the
right command for your macOS version, with a button to run it in Terminal.

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

Only do this for copies downloaded from this repository, ideally after
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

### Uninstall

1. If you turned on **Open at login** (in **Settings › General**), turn it off.
2. Quit Tartelette and move `/Applications/Tartelette.app` to the Trash.
3. Optionally, remove its data as well:

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
| Control | Request shutdown (graceful), power off, suspend, force quit, show the VM window | `SIGUSR2`, `stop`, `suspend` |
| Configure | CPU, memory, display (pt/px, refit), grow or replace the disk, new MAC/serial | `set` |
| Run options | Network (shared, bridged, Softnet allow/block/expose, host-only), shared folders, extra disks (image, cached VM, NBD), root disk caching/sync, Rosetta, nested virtualization, serial console, audio/USB/clipboard/input devices, first-boot provisioning | `run --net-* --dir --disk --root-disk-opts --rosetta --nested --serial …` |
| Access | IP address (DHCP, ARP or guest agent), Terminal shell in the guest, SSH, one-shot console | `ip`, `exec -it`, `exec` |
| Share | Push to registries (labels, chunked uploads, multiple tags), pull, export `.tvm`, clone, rename, delete | `push`, `pull`, `export`, `clone`, `rename`, `delete` |
| Registries | Log in/out; see Keychain, Docker config and environment credentials | `login --password-stdin`, `logout` |
| Storage | TART_HOME usage, per-VM allocation, cache breakdown, prune by age/budget/GC | `prune` |
| Monitor | Host CPU, memory, pressure, swap, thermal state; per-VM CPU (guest vs Tart), memory, disk I/O and power; guest CPU, load, memory, disk and uptime | — |

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

## Permissions macOS asks for

| When | What macOS asks | What to do |
|------|-----------------|------------|
| The first time you open a downloaded copy | Gatekeeper blocks it (the app isn't notarized) | [Open it for the first time](#3-open-it-for-the-first-time) |
| During live clipboard sync (macOS 15.4 or later) | Permission to read what you copy in other apps | **System Settings › Privacy & Security › Paste from Other Apps** → allow Tartelette |
| The first time you start a long job (create, clone, pull or push a VM…) | Permission to send notifications (they tell you when it finishes) | Optional; turn them off in **Settings › General › Notify when long operations finish** |
| When you enable Softnet | Your administrator password, once | **Settings › Registries & Network › Allow Softnet to Run…** |
| After an update, if you saved passwords | May ask for Keychain access | Allow it so the new version can read its passwords |

## Privacy

- **It doesn't go online by itself.** The app contains no networking code: no telemetry,
  analytics or update checks. Network traffic comes from `tart` (pulling, pushing, registry
  login), from `ssh` to your VMs when that fallback is used, and from links you open in your
  browser.
- **The clipboard stays on your Mac.** It travels between your Mac and your local VMs through
  `tart exec` (or SSH). Transfers are staged in `~/Library/Caches/Tartelette/Clipboard`.
- **Passwords.** The password from **Registries › Log In** goes to `tart login --password-stdin`
  through standard input and Tartelette doesn't keep it (Tart does). The SSH fallback password and
  the optional credentials in **Settings › Registries & Network** are stored in the macOS
  Keychain; they reach `ssh` through an askpass helper and `tart` as `TART_REGISTRY_*` variables,
  never as command-line arguments.
- **Not sandboxed, on purpose.** The app has to run `tart`, read `~/.tart` and inspect VM
  processes to measure their usage — things the macOS sandbox doesn't allow.

## Build from source

You need an Apple silicon Mac and **Xcode 26 or later** (tested with Xcode 27.0), which itself
needs macOS 15.6 or later ([Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)).
The app you build runs on macOS 14 or later. The project uses build settings introduced in Xcode 26 (default `MainActor`
isolation and approachable concurrency) and an Icon Composer app icon (`.icon`), so older Xcode
versions can't build it. Continuous integration builds the app and runs every test with Xcode 26.0.1
and 26.6. There are no third-party dependencies.

`xcodebuild` needs the full Xcode (the Command Line Tools alone aren't enough). If `make`
complains, select it:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

```bash
git clone https://github.com/lacrimae0rerum/tartelette.git
cd tartelette
make test       # TarteletteKit and app tests
make run        # Release build into build/Tartelette.app, then opens it
make install    # copies it to /Applications (pick another folder with INSTALL_DIR=…)
```

| Command | What it does |
|---------|--------------|
| `make test` | Runs the TarteletteKit (Swift Testing) and app test suites |
| `make build` | Release build into `build/Tartelette.app` |
| `make run` | Builds and opens the app |
| `make install` | Builds and installs it into `/Applications`, swapping out the previous copy atomically (`INSTALL_DIR=…` for another folder) |
| `make uninstall` | Removes the installed app |
| `make package` | Creates `dist/Tartelette-<version>.dmg`, `.zip` and `SHA256SUMS.txt` from the Release build |
| `make release` | Everything a release needs, in order: `check-assets`, `test`, `package` |
| `make assets` | Regenerates the app icon, menu bar icons and brand mark |
| `make check-assets` | Checks that the committed brand assets match their renderer |
| `make open` | Opens the project in Xcode |
| `make clean` | Removes `build/`, `dist/` and the package's build cache |

What you build on your Mac is ad-hoc signed for `arm64` and isn't quarantined, so it opens
without the Gatekeeper step.

## How it's built

```
Tartelette.xcodeproj        app target (synchronized folder, local package dependency)
Tartelette/                 SwiftUI app: App/, Stores/, Features/, Components/, Support/
TarteletteTests/            app tests
TarteletteKit/              Swift package, no third-party dependencies
  TarteletteCore            domain: VM models, typed tart commands, parsers, ports
  TarteletteCLI             adapter: runs tart, streams progress, launches VMs, Keychain, Softnet
  TarteletteMetrics         adapter: host + per-VM process metrics, storage usage
  TarteletteGuest           adapter: tart exec/SSH transports, clipboard bridge, guest metrics
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
| macOS says the app isn't supported on this type of Mac | It's an Intel Mac. Tart and Tartelette only run on Apple silicon. |
| macOS asks every time you copy something, or nothing goes from the Mac to the VM | Allow Tartelette in **System Settings › Privacy & Security › Paste from Other Apps** (the **Open Settings…** button in the **Clipboard & Files** tab takes you there). |
| "Tart isn't installed" | Install Tart (see [Install Tart](#1-install-tart)) or choose the binary with **Locate tart…** or in **Settings › General**. |
| `brew install openai/tools/tart` says "Refusing to load formula … from untrusted tap" | Homebrew 6 or later: run `brew trust --formula openai/tools/tart openai/tools/softnet` first. |
| Homebrew says "softnet: This formula does not run on macOS versions older than Sequoia" | You're on macOS 14: install Tart from its [official download](#1-install-tart). |
| Clipboard says the guest agent is unavailable | Use a `*-base`/`*-xcode` image, or install `tart-guest-agent` in the guest; make sure a user is logged in. |
| Softnet networking fails | **Settings › Registries & Network › Allow Softnet to Run…** (one-time administrator prompt). |
| A third macOS VM won't start | Apple allows two macOS guests at a time. |
| Exec/agent features fail with a source-built Tart | Source builds report `SNAPSHOT`, which the macOS guest agent rejects; use a released Tart. |

Something else? [Open an issue](https://github.com/lacrimae0rerum/tartelette/issues) (or use
**Help › Report an Issue…** in the app).

## License

Tartelette is available under the [MIT License](LICENSE). Tart is a separate project with its
own license; Tartelette contains no Tart code and runs the `tart` you install.
