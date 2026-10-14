# Set up Tartelette's MCP server

This guide is for AI agents. Follow it when your user asks you to set up Tartelette, or when you
meet Tartelette for the first time. Work through the steps in order; each one ends with a check.
People can read the [README](https://github.com/lacrimae0rerum/tartelette/blob/main/README.en.md#ai-agents-mcp)
instead.

> [!IMPORTANT]
> **Never grant yourself access.** Only the user turns agent access on and shares VMs, in the
> Tartelette app. Never edit `~/Library/Application Support/Tartelette/agents.json`, never change
> Tartelette's settings by any other means (`defaults`, scripting the app's interface…), and never
> run `tart` directly to get around a refusal. When something is refused, tell the user what to
> change and wait for them to do it.

## What you get

Tartelette is a macOS app for [Tart](https://tart.run) virtual machines. Its MCP server,
`tartelette-mcp`, ships inside the app and lets you use the VMs the user shares with you: start
and stop them, run commands in them, read and write their files, and clone disposable VMs
("sandboxes") to work in.

| It does | It never does |
|---------|---------------|
| Runs when your client launches it and talks over standard input and output | Listen on a network port |
| Works while the Tartelette app is closed | Give anything inside a VM a way to control the Mac |
| Applies the user's settings on every call | Show you VMs the user didn't share |
| Lets you delete the VMs you created | Let you delete any other VM |
| Logs every call to `~/Library/Logs/Tartelette/agents.log` | Log commands' standard input or file contents |

The access levels limit what you can do **through these MCP tools**. An agent that also has a
shell on the Mac could run `tart` directly, so the levels are guard rails that record the user's
intent, not a security boundary. Respect them as the user's decision.

## Quick path

1. [Check the Mac](#1-check-the-mac): Apple silicon, macOS 14 or later.
2. [Check that the helper runs](#2-check-that-the-helper-runs): `tartelette-mcp --version`.
3. [Check Tart](#3-check-tart): 2.27 or later. Only the user installs or updates it.
4. [Register the server](#4-register-the-server) with your client.
5. [Verify the connection](#5-verify-the-connection): call `list_vms`.
6. [Ask the user for access](#6-ask-the-user-for-access) if `list_vms` is refused or empty.

## 1. Check the Mac

```bash
uname -m                  # expect: arm64
sw_vers -productVersion   # expect: 14.0 or later
```

**Check:** `arm64` and macOS 14 or later. On an Intel Mac, stop: Tart and Tartelette don't run there.

## 2. Check that the helper runs

Tartelette is usually in `/Applications/Tartelette.app`. If it isn't there, find it:

```bash
mdfind "kMDItemCFBundleIdentifier == 'io.github.lacrimae0rerum.Tartelette'"
```

Use the copy in an Applications folder, not one on a mounted disk image (`/Volumes/…`). If
Tartelette isn't installed, tell the user and point them to the
[install steps](https://github.com/lacrimae0rerum/tartelette/blob/main/README.en.md#install).
Below, replace `/Applications/Tartelette.app` with the path you found.

```bash
/Applications/Tartelette.app/Contents/MacOS/tartelette-mcp --version; echo "exit $?"
```

**Check:** it prints `tartelette-mcp <version>` and `exit 0`. `--help` also prints the exact
registration command for this copy.

**If it's killed** (the shell prints `killed`, or the exit code is 137): the copy was downloaded
with a browser and still carries macOS's quarantine flag, so macOS kills the helper when it's
launched. Confirm it:

```bash
xattr -p com.apple.quarantine /Applications/Tartelette.app/Contents/MacOS/tartelette-mcp
```

If that prints a value, tell the user and ask them to run this command themselves, or to approve
explicitly that you run it. Never run it without that approval:

```bash
xattr -dr com.apple.quarantine /Applications/Tartelette.app
```

It should only be done for copies downloaded from the Tartelette repository, ideally after
[verifying the download](https://github.com/lacrimae0rerum/tartelette/blob/main/README.en.md#verify-the-download).
Then run `--version` again.

## 3. Check Tart

Tartelette and `tartelette-mcp` use the same Tart: the one the user chose in
**Settings › General**, otherwise the copy Tartelette manages, otherwise the first one found in
`/opt/homebrew/bin`, `/usr/local/bin`, `/Applications/tart.app` or the `PATH`. Check the managed
copy first:

```bash
"$HOME/Library/Application Support/Tartelette/Tart/current/tart.app/Contents/MacOS/tart" --version
tart --version
/Applications/tart.app/Contents/MacOS/tart --version   # installed by hand, as on macOS 14
```

The managed copy isn't on the `PATH` unless the user added it, so `tart: command not found` alone
doesn't mean Tart is missing.

**Never install or update Tart yourself**, and never change
`~/Library/Application Support/Tartelette/Tart`. If Tart is missing or older than 2.27, tell the
user: they can press **Install Tart** on Tartelette's **Tart Isn't Installed** screen, or
**Check for Updates** in **Settings › General › Tart** and update from there; Tartelette downloads
and verifies the official release. [Install Tart](https://github.com/lacrimae0rerum/tartelette/blob/main/README.en.md#1-install-tart)
in the README also has the Homebrew commands. A Tart built from source reports `SNAPSHOT`, which
the macOS guest agent rejects: use a released Tart.

**Check:** the first command that answers prints 2.27 or later.

## 4. Register the server

**Claude Code** (verified):

```bash
claude mcp add tartelette -- /Applications/Tartelette.app/Contents/MacOS/tartelette-mcp
claude mcp list
```

**Check:** `claude mcp list` shows `tartelette` as connected. By default Claude Code registers a
server for the current project only; ask the user whether they want it in every project
(`claude mcp add --scope user tartelette -- …`).

**Other MCP clients** (not tested): add this to the client's MCP configuration:

```json
{
  "mcpServers": {
    "tartelette": {
      "command": "/Applications/Tartelette.app/Contents/MacOS/tartelette-mcp"
    }
  }
}
```

**Check:** the client lists the `tartelette` tools. Some clients load MCP servers only at
startup: if the tools don't appear, ask the user to restart the client.

## 5. Verify the connection

Call `list_vms`.

| Result | Meaning | What to do |
|--------|---------|------------|
| A list of VMs, each with its state and access level | Everything works | Start working (see [Work well](#work-well)) |
| "Agent access is turned off…" | The user hasn't enabled agents | [Ask the user](#6-ask-the-user-for-access) to turn it on |
| An empty list | Agents are on, but no VM is shared | [Ask the user](#6-ask-the-user-for-access) to share VMs |
| "Tartelette's agent settings couldn't be read…" | The settings file is damaged | Ask the user to open **Settings › Agents** and choose **Reset Agent Settings…** (it turns agents off and unshares every VM) |
| "Tartelette couldn't find the tart executable…" | Tart is missing or in an unknown place | Go back to [step 3](#3-check-tart): ask the user to press **Install Tart** in Tartelette, or to choose Tart's location in **Tartelette › Settings** |
| The tool doesn't exist | The client didn't load the server | Go back to [step 4](#4-register-the-server) |

## 6. Ask the user for access

You can't do this step: only the user can, in the Tartelette app.

1. **Turn agents on:** **Settings › Agents** › **Let AI agents use Tartelette's VMs**.
2. **Share VMs:** for each VM, open its **Configuration** tab and pick a level under **Agent Access**.

| Level | You can |
|-------|---------|
| **None** (default) | Nothing: the VM isn't in your list |
| **Read** | See the VM and its settings |
| **Operate** | See it, start and stop it, run commands in it, read and write its files |
| **Template** | See it and clone sandboxes from it with `create_sandbox`; you fully control each sandbox, including deleting it |

Suggest **Template** for a VM you should experiment in, and **Operate** only for a VM the user
wants you to change directly. Changes apply on your next call: call `list_vms` again.

## Work well

- **Start with `list_vms`** in every session: it shows what you can use and at which level.
- **Prefer sandboxes.** `create_sandbox` clones a stopped **Template** VM into a VM you own. Work
  there, then delete it with `delete_vm`. Agents can have 4 VMs at a time by default.
- **Start before you use.** Call `start_vm` with `wait: true` before `exec`, `read_file` or
  `write_file`, so the Tart Guest Agent is answering. `create_sandbox` with `start: true` doesn't
  wait.
- **`exec`** runs in a login shell (`/bin/sh -lc`). It times out after 120 s by default
  (`timeout_seconds`, up to 1800 s). Standard output and standard error are each cut at 256 KiB;
  `stdoutTruncated` and `stderrTruncated` say when. Run long tasks in the background and check on
  them later.
- **`read_file`** returns at most 256 KiB per call: page through big files with `offset` and
  `length`. Bytes that aren't valid UTF-8 come back as base64.
- **`write_file`** accepts up to 50 MiB; send binary data with `encoding: "base64"`.
- **Content that starts with `data:` and contains a comma** is refused, because the MCP SDK
  would alter it. Send it base64-encoded.
- The limits above are the defaults; the user may have changed them.
- **At most two macOS VMs** can run at a time (Apple's limit). Stop one before starting another.

## Troubleshooting

| Symptom | Cause | What to do |
|---------|-------|------------|
| `tartelette-mcp` is killed (exit code 137), or the client says the server failed to start | Quarantine flag on a copy downloaded with a browser | Tell the user; remove the flag only with their explicit approval ([step 2](#2-check-that-the-helper-runs)) |
| `tart: command not found`, or "Tartelette couldn't find the tart executable…" | Tart isn't installed, or (for `command not found`) Tart is the copy Tartelette manages, which isn't on the `PATH` | [Step 3](#3-check-tart); never install Tart yourself |
| "The Tart Guest Agent in “…” isn't answering" | The VM is still booting, or the guest has no Tart Guest Agent | Call `start_vm` with `wait: true`; otherwise ask the user to use a Cirrus Labs image or install `tart-guest-agent` in the guest |
| "Agent access is turned off…" | Agents are off | [Ask the user](#6-ask-the-user-for-access) to turn them on |
| A VM is missing from `list_vms`, or "VM “…” isn't shared with agents" | The VM isn't shared | [Ask the user](#6-ask-the-user-for-access) to share it |
| "…is shared with agents as Read, which doesn't allow…" | The level is too low for that tool | Ask the user to set the level the message names |
| "Agents already have 4 VMs…" | Agent VM limit reached | Delete a sandbox you no longer need, or ask the user whether to raise the limit |
| The `tartelette` tools don't appear in the client | The client loads servers only at startup, or the app moved | Ask the user to restart the client; if Tartelette moved, register it again with the new path (in Claude Code, `claude mcp remove tartelette`, then [step 4](#4-register-the-server)) |

## More

- [AI agents (MCP) in the README](https://github.com/lacrimae0rerum/tartelette/blob/main/README.en.md#ai-agents-mcp):
  every tool, limit, and the log and settings files.
- [Troubleshooting in the README](https://github.com/lacrimae0rerum/tartelette/blob/main/README.en.md#troubleshooting).
