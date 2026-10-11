# GhosttyEXTREME

A macOS terminal for running coding agents — Claude Code, Codex and others — in several
projects at once. It is a fork of [Ghostty](https://ghostty.org): the terminal underneath is
Ghostty's own, so its configuration, themes, keybindings and shell integration work as they
do upstream, and this branch keeps up with official Ghostty releases.

What the fork builds around it is aimed at the agents:

- **A sidebar of projects, not of tabs.** Sessions are grouped under the folder they work in,
  each with its agent's state: working, waiting on you, or done.
- **Agent surfaces.** A session says what its agent is doing, what it is waiting for, and
  which part of the project it is touching — a permission prompt is answered from the
  sidebar, without switching tabs to find it.
- **An editor that follows.** Open the file an agent is editing, with a code map and a diff
  for each change it has made.
- **Notes that outlive a session.** What an agent writes down about a project is there for
  the next one, and one agent can hand its work to another.
- **A review inbox.** The changes an agent finishes collect in one place: read them file by
  file, comment, commit — or undo the whole turn.
- **Dev servers as sessions.** A local server and the ports it listens on sit next to the
  session that started it.

Requires macOS 13 or newer, on Apple silicon (arm64).

- Download: [latest release](https://github.com/steventsvik/GhosttyEXTREME/releases/latest)
- Website: <https://steventsvik.github.io/GhosttyEXTREME/>
- What changed: [CHANGELOG.md](CHANGELOG.md)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/steventsvik/GhosttyEXTREME/custom/install.sh | bash
```

The script fetches the latest release, checks the download against the release's
`SHA256SUMS`, and puts **GhosttyEXTREME.app** in `/Applications`, keeping the previous copy
until the new one is in place. Nothing else on the system is touched.

By hand, from the [releases page](https://github.com/steventsvik/GhosttyEXTREME/releases/latest):
download `GhosttyEXTREME-<version>-macos-arm64.zip`, unzip it, and move
**GhosttyEXTREME.app** to `/Applications`. The app is signed but not notarized by Apple, so
clear the download quarantine once:

```sh
xattr -dr com.apple.quarantine /Applications/GhosttyEXTREME.app
```

## Build from source

- macOS 13 or newer, on Apple silicon
- Xcode 26 or newer
- Zig 0.15 from Homebrew — `brew install zig@0.15`. A Zig built from ziglang.org does not
  link against recent macOS SDKs.
- `jq`, which the agent hooks use — `brew install jq`

```sh
git clone https://github.com/steventsvik/GhosttyEXTREME.git
cd GhosttyEXTREME
/opt/homebrew/opt/zig@0.15/bin/zig build -Doptimize=ReleaseFast -Dxcframework-target=native
ditto macos/build/ReleaseLocal/Ghostty.app /Applications/GhosttyEXTREME.app
```

`zig build` is the whole build: it produces the core and the app. Two scripts come with the
repo for iterating:

- `./dev-install.sh` builds only the app and installs it as **Ghostty Ex** in
  `~/Applications` — the copy to develop against. It has the same bundle identifier as the
  released app, so macOS treats the two as one: quit one before running the other. Build the
  core first (`zig build`, as above) whenever anything outside `macos/` has changed.
- `./update-ghostty.sh` moves the `custom` branch onto the newest official Ghostty release,
  rebuilds and installs it. `./update-ghostty.sh --check` only reports whether a newer release
  exists. It needs an `upstream` remote pointing at
  [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty).

If the clone lives somewhere iCloud syncs — Desktop or Documents — codesign fails on iCloud's
extended attributes. Keep `macos/build` outside iCloud; `update-ghostty.sh` does that for you.

## Agent status setup

The welcome window, and **Check Setup** in the app, connect Claude Code, Codex and your shell
by themselves — that is all most people need. To do it by hand, run

```sh
./agent-hooks/install.sh
```

which copies the hooks to `~/.ghostty-extreme/agent-hooks/` and the `localhost` command to
`~/.ghostty-extreme/bin/`. Point your agents at those copies rather than at the repo: macOS
may refuse a terminal process access to `~/Desktop` or `~/Documents`, which breaks the hooks
without saying so. The scripts do nothing outside GhosttyEXTREME's own terminals, which set
`GHOSTTY_EXTREME_AGENT_EVENTS=1`.

## Contributing

Issues and pull requests for this fork's own features are welcome, and pull requests go to
the `custom` branch. Bugs that also happen in official Ghostty belong upstream. See
[CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md) for reporting a security
problem.

## License and credits

GhosttyEXTREME is [AGPL-3.0](LICENSE). It is a fork of [Ghostty](https://ghostty.org), whose
code is MIT ([LICENSE-GHOSTTY](LICENSE-GHOSTTY)); parts of the sidebar are derived from
[Warp](https://github.com/warpdotdev/warp), also AGPL-3.0. Credits and trademark notes are in
[NOTICE.md](NOTICE.md).

Ghostty's own documentation — configuration, themes, keybindings — is at
[ghostty.org/docs](https://ghostty.org/docs).
