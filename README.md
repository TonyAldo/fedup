# fedup

```
      ▐▛███▜▌
     ▟██████▙     f e d u p
    ▐████████▌    ─────────────────────────────
     ▜██████▛     Fedora Update Utility
      ▘▘ ▝▝
```

**The everything-updater for Fedora.** A single-file bash TUI that unifies every update path on a Fedora system — dnf, Flatpak, Snap, device firmware, and containers — with pre-update Btrfs snapshots, per-package selection, security-only mode, scheduled checks, and remote multi-host support.

Built for Fedora. Zero dependencies beyond a stock install — anything optional (snapper, versionlock plugin, snapd…) is detected at runtime and offered for installation when you first use the feature.

## Why

Fedora spreads updates across half a dozen tools: `dnf` for packages, `flatpak` for Flathub apps, `snap` if you use it, `fwupdmgr` for BIOS/SSD/dock firmware, `distrobox`/`toolbox` for containers, plus snapper for safety snapshots and dnf plugins for holds and security filtering. fedup wraps all of it in one keyboard-driven menu — and one `--all` flag for when you don't want a menu at all.

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
```

(The built-in timer installer does this for you — see [Automation](#automation).)

## Usage

```
fedup                     interactive menu
fedup --all               update everything, no menu
fedup --security          apply security updates only
fedup --check             count pending updates (exit 0 = none, 10 = some)
fedup --check --notify    same, plus a desktop notification
fedup --check --json      machine-readable counts
fedup --dry-run <mode>    preview any of the above without changing anything
fedup --remote h1 h2      run --all on remote hosts over SSH
fedup --remote-check h1   run --check on remote hosts (--json = JSON array)
fedup --help              usage summary
```

## Features

### 🎯 Pick your updates
An interactive checklist built from `dnf check-update`: arrow keys to move, **space** to toggle, **a**/**n** for all/none of the visible list, **/** to filter by name substring, **c** to read a package's changelog or advisory before committing, **p** to pin the package via versionlock so it stops appearing in future update sets.

### 🛡️ Security-only updates
Shows the advisory severity summary and per-CVE list, then applies only `dnf upgrade --security`. Also available non-interactively as `fedup --security`.

### 📸 Snapshots before every update
On Btrfs roots, every update action takes a snapshot first. Prefers **snapper** (with linked pre/post snapshot pairs, so `snapper status` shows exactly what a transaction changed); offers to install and configure it if missing; falls back to a raw read-only `btrfs subvolume snapshot`. Skips gracefully on non-Btrfs filesystems.

### 🔌 Firmware, containers, codecs
- **fwupd/LVFS**: refresh metadata, list pending BIOS/SSD/dock/peripheral firmware, stage for next reboot.
- **distrobox / toolbox**: upgrade all containers.
- **RPM Fusion**: enable free+nonfree keyed to your release, swap in full ffmpeg, update the multimedia group, and auto-detect Intel/AMD GPUs for the correct VA-API driver swap.

### ♻️ Avoid unnecessary reboots
`dnf needs-restarting --services` lists services running against updated libraries and restarts them in place. Tells you honestly when a kernel/core-library change means a real reboot is needed.

### 🌐 Mirror & download tuning
Enables `fastest_mirror` and `max_parallel_downloads=10` in `/etc/dnf/dnf.conf` and rebuilds the metadata cache.

### 🩺 COPR health check
Probes every enabled COPR's `repomd.xml` for your current `$releasever` and offers to disable dead repos — the most common cause of dnf errors after a Fedora version bump.

### 📜 History reports
Every update action writes a report to `~/.local/share/fedup/history/` including the full dnf transaction. View and prune old reports (keep 10 newest / delete >30 days / wipe) from the menu.

### ▷ Dry-run mode
`--dry-run` previews anything. dnf operations show the *real* resolved transaction via `--assumeno`; everything else narrates what would run without executing.

### ⬢ Atomic-aware
Detects image-based Fedora (Kinoite, Silverblue, bootc) via `/run/ostree-booted`, guards all dnf-mutating features from doing damage, and routes base-image updates through `rpm-ostree upgrade` instead. Flatpak, firmware, and container updates work as normal.

## Configuration

`~/.config/fedup/config` — created with a commented template via the menu (⚙️ Edit fedup configuration). Parsed as whitelisted key=value data, never executed.

```ini
ALWAYS_SNAPSHOT=false   # snapshot without asking (raw btrfs fallback too)
SKIP_FLATPAK=false      # skip flatpak in 'update everything' & counts
SKIP_SNAP=false
SKIP_FIRMWARE=false
SKIP_CONTAINERS=false
AUTOREMOVE=true         # dnf autoremove at end of 'update everything'
```

## Automation

The menu's timer installer sets up either or both:

- **Daily check (user timer)** — runs `fedup --check --notify`; you get a desktop notification when updates are pending. Copies the script to `~/.local/bin/fedup`.
- **Weekly auto-update (system timer)** — runs `fedup --all` unattended, Sundays ~4 AM. Copies the script to `/usr/local/bin/fedup`.

```bash
systemctl --user list-timers fedup-check.timer     # inspect
sudo systemctl disable --now fedup-auto.timer      # opt out
```

`--check` exits **0** when clean and **10** when updates are pending, so it composes cleanly with scripts and monitoring.

## Remote mode

```bash
fedup --remote homelab1 homelab2          # full update on each host over SSH
fedup --remote-check homelab1 --json      # aggregate JSON array of pending counts
```

Requires SSH key auth to each host. `--json` output is a valid JSON array with per-host `ok`/`error` fields; exit code is non-zero if any host failed — cron- and dashboard-friendly.

```json
[{"host":"homelab1","dnf":12,"security":3,"flatpak":2,"snap":0,"firmware":1,"total":15,"reboot_needed":false}]
```

## Requirements

- Fedora (developed against Fedora 44, dnf5)
- bash 4+, plus base-system tools (dnf, sudo, curl, findmnt, systemctl — all preinstalled)
- Optional, offered on demand: `snapper`, `dnf5-plugins` (versionlock/changelog/needs-restarting), `snapd`, `fwupd`, `distrobox`

## Disclaimer

fedup runs privileged package transactions. Read the script before running it — it's one file and commented for exactly that reason. Test destructive-adjacent features (snapshots, auto-update timers) with `--dry-run` first. No warranty; see [LICENSE](LICENSE).

## License

MIT © Anthony Aldorasi
