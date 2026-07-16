# fedup

```
      ▐▛███▜▌
     ▟██████▙     f e d u p  v3.0
    ▐████████▌    ─────────────────────────────
     ▜██████▛     Fedora Update Utility
      ▘▘ ▝▝
```

**The everything-updater for Fedora.** A single-file bash TUI that unifies every update path on a Fedora system — dnf, Flatpak, Snap, firmware, containers, and optional user-space tools — with pre-update Btrfs snapshots, safety gates, offline upgrades, and remote multi-host support.

Built for Fedora. Zero dependencies beyond a stock install — anything optional (snapper, versionlock plugin, snapd, whiptail…) is detected at runtime and offered when you use the feature.

## Why

Fedora spreads updates across half a dozen tools: `dnf` for packages, `flatpak` for Flathub apps, `snap` if you use it, `fwupdmgr` for BIOS/SSD/dock firmware, `distrobox`/`toolbox` for containers, plus cargo/pipx/npm/brew for user tooling. fedup wraps all of it in one keyboard-driven menu — and one `--all` flag for when you don't want a menu at all.

## Install

```bash
git clone git@github.com:TonyAldo/fedup.git
cd fedup
chmod +x fedup.sh
./fedup.sh
```

Optionally put it on your PATH:

```bash
cp fedup.sh ~/.local/bin/fedup
fedup --install-completion   # bash + zsh
```

## Usage

```
fedup                          interactive menu
fedup --all                    update everything, no menu
fedup --security               apply security updates only
fedup --check                  count pending updates (exit 0 = none, 10 = some)
fedup --check --notify         same, plus a desktop notification
fedup --check --json           machine-readable counts
fedup --dry-run <mode>         preview any of the above without changing anything
fedup --offline                download full upgrade for apply-at-reboot
fedup --remote h1 h2           run --all on remote hosts over SSH
fedup --remote-check h1        run --check on remote hosts (--json = JSON array)
fedup --doctor                 free space, power, size estimate, pending counts
fedup --self-update            pull latest fedup.sh (git or URL)
fedup --install-completion     install bash/zsh completions
fedup --whiptail               force whiptail/dialog UI (or set USE_WHIPTAIL=true)
fedup --help                   usage summary
```

## Features

### 🎯 Pick your updates
Interactive checklist from `dnf check-update`: arrows / **mouse click**, **space** to toggle, **a**/**n**, **/** filter, **c** changelog, **p** versionlock pin. Flatpak has the same pick-and-choose flow.

### 🛡️ Security-only & offline upgrades
- Security: advisory summary + `dnf upgrade --security`
- Offline: download now, apply at reboot via `dnf offline`

### 📸 Snapshots & rollback
Btrfs pre/post snapshots via snapper (or raw RO snapshot). Menu rollback wizard wraps `snapper rollback`.

### 🔌 Firmware, containers, groups, codecs
- **fwupd/LVFS**, **distrobox / toolbox**, **dnf group upgrade**, **dnf modules**
- **RPM Fusion** codecs + Intel/AMD VA-API helpers

### 🧰 User-space (opt-in)
cargo-update, pipx, npm -g, Homebrew, AppImages (`appimageupdatetool`). Off by default (`SKIP_USERSPACE=true`).

### 🧹 Kernel cleanup
List kernels, keep N newest (+ always the running one), remove the rest.

### ♻️ Avoid unnecessary reboots
`dnf needs-restarting` for reboot hint + in-place service restarts.

### 🛡️ Safety gates
Before big upgrades:
- **Disk preflight** — require `MIN_FREE_GB` free on `/` and `/var`
- **Battery gate** — optional `REQUIRE_AC=true`
- **Exclude globs** — `EXCLUDE=kernel*,akmod*` (picker + dnf)
- **Size estimate** — download size + rough ETA

### 🔍 UX extras
- Unified search across dnf / flatpak / snap / firmware
- History reports + **diff/summary of last run**
- Mouse support in menus; optional **whiptail/dialog** backend
- Shell completions (bash/zsh)
- **Self-update** from git or GitHub raw URL

### 🌐 Mirrors, COPR, timers, remote
Mirror tuning, COPR health check, daily notify timer, weekly `--all` timer, SSH multi-host mode.

### ⬢ Atomic-aware
Detects image-based Fedora, guards dnf mutations, uses `rpm-ostree upgrade` for the base image.

## Configuration

`~/.config/fedup/config` — created from the menu. Parsed as whitelisted data, never executed.

```ini
ALWAYS_SNAPSHOT=false
SKIP_FLATPAK=false
SKIP_SNAP=false
SKIP_FIRMWARE=false
SKIP_CONTAINERS=false
SKIP_USERSPACE=true       # cargo/pipx/npm/brew/AppImage
AUTOREMOVE=true
REQUIRE_AC=false
MIN_FREE_GB=2
KERNEL_KEEP=2
USE_WHIPTAIL=false
# EXCLUDE=kernel*,akmod*
# APPIMAGE_DIRS=~/Applications:~/.local/bin
# SELF_UPDATE_URL=https://raw.githubusercontent.com/TonyAldo/fedup/main/fedup.sh
```

## Automation

- **Daily check (user timer)** — `fedup --check --notify`
- **Weekly auto-update (system timer)** — `fedup --all` Sundays ~4 AM

```bash
systemctl --user list-timers fedup-check.timer
sudo systemctl disable --now fedup-auto.timer
```

`--check` exits **0** when clean and **10** when updates are pending.

## Remote mode

```bash
fedup --remote homelab1 homelab2
fedup --remote-check homelab1 --json
```

Requires SSH key auth. Remote copy is cleaned up after the run.

## Requirements

- Fedora (developed against Fedora 44 / dnf5)
- bash 4+, stock tools (dnf, sudo, curl, findmnt, systemctl)
- Optional: snapper, dnf5-plugins, snapd, fwupd, distrobox, whiptail, cargo-update, appimageupdatetool

## Disclaimer

fedup runs privileged package transactions. Read the script before running it. Prefer `--dry-run` first for destructive-adjacent features (snapshots, rollback, offline reboot, auto timers). No warranty; see [LICENSE](LICENSE).

## License

MIT © Anthony Aldorasi
