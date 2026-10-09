# Tartelette

A native macOS companion app for [Tart](https://tart.run): create, run, configure, share and
monitor Tart virtual machines without the terminal — with live performance metrics and a
clipboard that really works in both directions (text, rich text, images and files).

Tartelette drives the `tart` executable you already have installed, so everything it does is
exactly what the CLI does. Every sheet shows the equivalent `tart …` command, ready to copy.

## Quick path

1. Install Tart: `brew install openai/tools/tart`
2. Build and install the app: `make install` (or `make run` to just try it)
3. Open **Tartelette**, press **⌘N**, pick *macOS Tahoe* (or *Ubuntu*) and click **Download & Create**.
4. Select the VM and press **⌘R**. Copy something on your Mac — it's already on the VM's clipboard.

Requirements: Apple silicon, macOS 14 or later, Tart 2.x. Building needs Xcode 16 or later.

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

## Copy and paste between Mac and VM

Tart's built-in clipboard sharing (SPICE) is text-only, and on macOS guests the agent can replace
rich content on your Mac with plain text. Tartelette adds its own **clipboard bridge**:

| | Tartelette Bridge | Tart (SPICE) |
|---|---|---|
| Content | Text, RTF, HTML, PNG/TIFF images, files and folders | Plain text |
| Direction | Both, live (or one-way, or manual) | Both |
| Needs | Tart Guest Agent (Cirrus `*-base`, `*-xcode`, Linux images) | Guest agent / `spice-vdagent` |

How it works: Tartelette watches your Mac's pasteboard and polls the guest's through
`tart exec`, moves every payload with a SHA-256 check (falling back to verified 128 KiB chunks
when a transfer is corrupted — see tart#1347), and remembers what it wrote on each side so
nothing echoes back. Copied files are staged in the guest and placed on its pasteboard, so
**⌘V in Finder pastes them**. You can also drop files on a VM to copy them to its Desktop.

Pick the engine per VM in **Run Options → Clipboard & Address** (or **Clipboard & Files →
Change…**): *Automatic* (bridge for macOS guests, SPICE for Linux), *Tartelette Bridge*,
*Tart (SPICE)* or *Off*. With the bridge, VMs start with
`--no-clipboard` so the two mechanisms never fight.

Linux guests need a desktop session plus `wl-clipboard` or `xclip`/`xsel`; the Cirrus Labs
server images have no desktop, so the bridge reports clipboard as unavailable there (file
transfer, console and metrics still work).

Good to know:

- A change is synced once it has settled: half-written clipboards (an app still adding items)
  and file items their app hasn't handed over yet are retried instead of sent partially.
- For 10 seconds after a sync, a copy of *some* of the just-synced files counts as an echo and
  isn't sent back. Copy them again after that window if you meant it.
- Only one Tartelette runs at a time: launching a second copy brings the first one forward, so
  two copies never sync the same VM against each other.

## Build from source

```bash
make test      # TarteletteKit unit tests (Swift Testing)
make build     # Release build → build/Tartelette.app
make install   # copies the app to /Applications
make assets    # regenerates the icon, menu bar icons and brand mark
make open      # opens the Xcode project
```

The app is ad-hoc signed ("Sign to Run Locally") and not sandboxed: it must run `tart`, read
`~/.tart` and inspect VM processes.

## How it's built

```
Tartelette/
  Tartelette.xcodeproj      app target (synchronized folder, local package dependency)
  Tartelette/               SwiftUI app: App/, Stores/, Features/, Components/, Support/
  TarteletteKit/            Swift package, no third-party dependencies
    TarteletteCore          domain: VM models, typed tart commands, parsers, ports
    TarteletteCLI           adapter: runs tart, streams progress, launches VMs, Keychain, Softnet
    TarteletteMetrics       adapter: host + per-VM process metrics, storage usage
    TarteletteGuest         adapter: tart exec/SSH transports, clipboard bridge, guest metrics
  Tools/BrandKit            code-drawn Liquid Glass app icon and menu bar icons
```

| Topic | Decision |
|-------|----------|
| Source of truth | The `tart` binary. Polling uses `tart list --format json` plus each VM's `config.json`, never `tart get` (it changes access dates used by `prune`). |
| Running VMs | `tart run` is spawned in its own session with output in `~/Library/Logs/Tartelette/<vm>.log`, so VMs keep running if the app quits. The running PID comes from Tart's `fcntl` lock on `config.json`, so VMs started from Terminal are controlled the same way. |
| Progress | Tart runs with `CI=1` (plain `N%` lines) and a PATH that includes Homebrew, so Softnet and Docker credential helpers are found. Cancelling sends `SIGINT`, which makes Tart clean up. |
| Per-VM metrics | Each VM runs in a `com.apple.Virtualization.VirtualMachine` XPC process; it's matched to its VM by the disk and NVRAM files it holds open. CPU time from `proc_pid_rusage` is converted from Mach ticks; power comes from the kernel's energy counter. |
| Secrets | Registry passwords go to Tart via stdin only and are never kept. SSH fallback passwords live in the Keychain and reach `ssh` through an askpass helper, never argv. |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Tart isn't installed" | Install Tart or choose the binary in **Settings → General**. |
| Clipboard says the guest agent is unavailable | Use a `*-base`/`*-xcode` image, or install `tart-guest-agent` in the guest; make sure a user is logged in. |
| Softnet networking fails | **Settings → Registries & Network → Allow Softnet to Run…** (one-time administrator prompt). |
| A third macOS VM won't start | Apple allows two macOS guests at a time. |
| Exec/agent features fail with a source-built Tart | Source builds report `SNAPSHOT`, which the macOS guest agent rejects; use a released Tart. |
