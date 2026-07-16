#!/usr/bin/env bash
#
#      ▐▛███▜▌      f e d u p  v3.0
#     ▟██████▙      ────────────────────────────────────────
#    ▐████████▌     The everything-updater for Fedora
#     ▜██████▛      dnf · flatpak · snap · firmware · containers
#      ▘▘ ▝▝        snapshots · versionlock · security · timers
#
#  USAGE
#    fedup                     interactive menu
#    fedup --all               update everything, no menu
#    fedup --security          apply security updates only
#    fedup --check             count pending updates (exit 0 = none, 10 = some)
#    fedup --check --notify    same, plus desktop notification
#    fedup --check --json      machine-readable counts
#    fedup --dry-run <mode>    preview any of the above without changing anything
#    fedup --remote h1 h2 ...  run --all on remote hosts over SSH
#    fedup --remote-check h1   run --check --json on remote hosts (--json = JSON array)
#    fedup --offline           download updates for offline/reboot apply
#    fedup --self-update       pull latest fedup.sh from upstream
#    fedup --doctor            (alias) quick pending + free-space + power summary
#    fedup --install-completion  install bash/zsh completions
#
#  FILES
#    ~/.config/fedup/config          user config (skip sources, excludes, safety…)
#    ~/.local/share/fedup/history/   per-run transaction reports
#    ~/.config/systemd/user/         fedup-check.timer (if installed)
#    ~/.local/share/bash-completion/completions/fedup
#    ~/.zfunc/_fedup                 (zsh completion, if installed)
#
set -o pipefail

VERSION="3.0"
HIST_DIR="$HOME/.local/share/fedup/history"
mkdir -p "$HIST_DIR" 2>/dev/null
# Temp files created during a run (spinner logs, etc.) — cleaned on EXIT
FEDUP_TMPFILES=()
# Upstream for --self-update (override in config)
SELF_UPDATE_URL="https://raw.githubusercontent.com/TonyAldo/fedup/main/fedup.sh"

# ─────────────────────────── Config file ──────────────────────────────
CONFIG_FILE="$HOME/.config/fedup/config"
# Defaults (overridable in $CONFIG_FILE)
ALWAYS_SNAPSHOT=false     # take snapshots without asking (raw btrfs fallback too)
SKIP_FLATPAK=false        # skip flatpak in 'update everything' & counts
SKIP_SNAP=false           # skip snap in 'update everything' & counts
SKIP_FIRMWARE=false       # skip fwupd in 'update everything' & counts
SKIP_CONTAINERS=false     # skip distrobox/toolbox in 'update everything'
SKIP_USERSPACE=true       # skip cargo/pipx/npm/brew/appimage (opt-in)
AUTOREMOVE=true           # run dnf autoremove at end of 'update everything'
REQUIRE_AC=false          # block big upgrades on battery
USE_WHIPTAIL=false        # use whiptail/dialog for confirms + simple menus when available
KERNEL_KEEP=2             # kernels to keep (plus the running one) during cleanup
MIN_FREE_GB=2             # minimum free GiB on / and /var before upgrades
EXCLUDE=""                # comma-separated dnf exclude globs, e.g. kernel*,akmod*
APPIMAGE_DIRS="$HOME/Applications:$HOME/.local/bin:$HOME/bin"

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local key val
    # Whitelisted keys only — the config is data, never executed.
    while IFS='=' read -r key val; do
        key="${key//[[:space:]]/}"
        # Keep value spaces for path lists; strip trailing comments and surrounding spaces
        val="${val%%#*}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
            ALWAYS_SNAPSHOT|SKIP_FLATPAK|SKIP_SNAP|SKIP_FIRMWARE|SKIP_CONTAINERS|SKIP_USERSPACE|AUTOREMOVE|REQUIRE_AC|USE_WHIPTAIL)
                val="${val//[[:space:]]/}"
                [[ "$val" =~ ^(true|false)$ ]] && printf -v "$key" '%s' "$val";;
            KERNEL_KEEP|MIN_FREE_GB)
                val="${val//[[:space:]]/}"
                [[ "$val" =~ ^[0-9]+$ ]] && printf -v "$key" '%s' "$val";;
            EXCLUDE|APPIMAGE_DIRS|SELF_UPDATE_URL)
                [[ -n "$val" ]] && printf -v "$key" '%s' "$val";;
        esac
    done < <(grep -E '^[A-Z_]+=' "$CONFIG_FILE" 2>/dev/null)
}
load_config

# ─────────────────────────── Dry-run mode ─────────────────────────────
DRY_RUN=false
run() {  # run <cmd...> — execute, or narrate in dry-run mode
    if $DRY_RUN; then
        printf "  \033[38;5;221m▷ dry-run:\033[0m %s\n" "$*"
        return 0
    fi
    "$@"
}

# ──────────────── Image-based Fedora (Atomic/bootc) ───────────────────
IS_ATOMIC=false
[[ -e /run/ostree-booted ]] && IS_ATOMIC=true

guard_atomic() {  # returns 1 (and redirects the user) on image-based systems
    $IS_ATOMIC || return 0
    warn "Image-based Fedora detected (Kinoite/Silverblue/Atomic/bootc)."
    info "dnf does not manage packages on this system — layering/updates go through rpm-ostree."
    if command -v rpm-ostree &>/dev/null && confirm "Run 'rpm-ostree upgrade' instead?"; then
        run sudo rpm-ostree upgrade
    fi
    return 1
}

# ─────────────────────────────── Style ────────────────────────────────
ESC=$'\033'
RESET="${ESC}[0m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"
FG_BLUE="${ESC}[38;5;75m"; FG_CYAN="${ESC}[38;5;51m"; FG_GREEN="${ESC}[38;5;114m"
FG_YELLOW="${ESC}[38;5;221m"; FG_RED="${ESC}[38;5;203m"; FG_MAGENTA="${ESC}[38;5;177m"
FG_GRAY="${ESC}[38;5;245m"; FG_WHITE="${ESC}[38;5;255m"; FG_ORANGE="${ESC}[38;5;215m"
BG_SEL="${ESC}[48;5;24m"

OK="${FG_GREEN}✔${RESET}"; WARN="${FG_YELLOW}⚠${RESET}"; ERR="${FG_RED}✘${RESET}"
ARROW="${FG_CYAN}❯${RESET}"; PIN="${FG_ORANGE}⚲${RESET}"

hr()    { printf "${FG_GRAY}%s${RESET}\n" "──────────────────────────────────────────────────────────────────"; }
title() { printf "\n${BOLD}${FG_CYAN}%s${RESET}\n" "$1"; hr; }
info()  { printf "  ${FG_BLUE}ℹ${RESET}  %s\n" "$1"; }
good()  { printf "  ${OK}  %s\n" "$1"; }
warn()  { printf "  ${WARN}  %s\n" "$1"; }
fail()  { printf "  ${ERR}  %s\n" "$1"; }

# BANNER_ROWS: 1-based last row printed by banner() after clear (for mouse hit-testing).
BANNER_ROWS=0
banner() {
    clear
    BANNER_ROWS=0
    printf "${FG_MAGENTA}"
    printf '      ▐▛███▜▌\n'
    printf '     ▟██████▙     f e d u p  v%s\n' "$VERSION"
    printf '    ▐████████▌    ─────────────────────────────\n'
    printf '     ▜██████▛     Fedora Update Utility\n'
    printf '      ▘▘ ▝▝\n'
    BANNER_ROWS=5   # logo block above
    printf "${RESET}"
    printf "  ${FG_GRAY}%s · kernel %s · %s${RESET}\n" \
        "$(source /etc/os-release && echo "$PRETTY_NAME")" \
        "$(uname -r)" \
        "$(date '+%a %b %d, %I:%M %p')"
    (( ++BANNER_ROWS ))
    $DRY_RUN   && { printf "  ${FG_YELLOW}▷ DRY-RUN MODE — nothing will be changed${RESET}\n"; (( ++BANNER_ROWS )); }
    $IS_ATOMIC && { printf "  ${FG_ORANGE}⬢ image-based system (rpm-ostree) — dnf features are guarded${RESET}\n"; (( ++BANNER_ROWS )); }
    echo
    (( ++BANNER_ROWS ))
}

# Internal: run cmd with animated spinner. Optional capture varname gets full log.
# Exit 0 and 100 (dnf "updates available") both count as success visuals.
_spinner_impl() {
    local _capvar="$1"; shift
    local msg="$1"; shift
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    local spinlog
    spinlog=$(mktemp "${TMPDIR:-/tmp}/fedup_spin.XXXXXX") || spinlog=$(mktemp)
    FEDUP_TMPFILES+=("$spinlog")
    "$@" &> "$spinlog" &
    local pid=$!
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${FG_CYAN}%s${RESET}  %s" "${frames:i++%10:1}" "$msg"
        sleep 0.08
    done
    wait "$pid"; local rc=$?
    tput cnorm 2>/dev/null
    if (( rc == 0 || rc == 100 )); then
        printf "\r  ${OK}  %s   \n" "$msg"
    else
        printf "\r  ${ERR}  %s   \n" "$msg"
        scrub_progress < "$spinlog" | tail -n 6 | sed 's/^/     /'
    fi
    if [[ -n "$_capvar" ]]; then
        # nameref so assignment lands in the caller's local (not a new global)
        local -n _capref="$_capvar"
        _capref=$(cat "$spinlog" 2>/dev/null)
    fi
    rm -f "$spinlog"
    return $rc
}

spinner() {  # spinner "message" -- command...
    local msg="$1"; shift
    _spinner_impl "" "$msg" "$@"
}

# Like spinner, but stores combined stdout+stderr into the named variable.
spinner_capture() {  # spinner_capture varname "message" -- command...
    local __var="$1"; shift
    local msg="$1"; shift
    local __buf=""
    _spinner_impl __buf "$msg" "$@"
    local rc=$?
    printf -v "$__var" '%s' "$__buf"
    return $rc
}

# True when a human is watching (TTY) and we're not emitting machine JSON.
# Used to gate spinners on interactive menu paths that hit the network.
_ui_progress() {
    [[ -t 1 ]] && ! ${JSON_OUT:-false}
}

# Spinner that always paints ✔ (for probes where non-zero just means "nothing").
# Captures stdout+stderr into varname; always returns 0.
spinner_soft() {  # spinner_soft varname "message" -- command...
    local __var="$1"; shift
    local msg="$1"; shift
    local __buf=""
    # Force success visual; real rc is not useful for "is anything pending?" probes.
    _spinner_impl __buf "$msg" bash -c '"$@"; exit 0' _ "$@"
    printf -v "$__var" '%s' "$__buf"
    return 0
}

# Prefer whiptail/dialog when USE_WHIPTAIL=true and a backend exists.
_dialog_bin() {
    $USE_WHIPTAIL || return 1
    command -v whiptail &>/dev/null && { echo whiptail; return 0; }
    command -v dialog &>/dev/null && { echo dialog; return 0; }
    return 1
}

confirm() {
    local ans bin
    if bin=$(_dialog_bin); then
        "$bin" --yesno "$1" 8 60 2>/dev/null
        return $?
    fi
    printf "  ${FG_YELLOW}?${RESET}  %s ${FG_GRAY}[y/N]${RESET} " "$1"
    read -r ans
    [[ "$ans" =~ ^[Yy] ]]
}

pause() { printf "\n  ${FG_GRAY}press Enter to return to menu…${RESET}"; read -r; }

# Enable xterm mouse tracking (SGR). Caller should mouse_off on exit.
mouse_on()  { printf '\033[?1000h\033[?1006h' 2>/dev/null; }
mouse_off() { printf '\033[?1000l\033[?1006l' 2>/dev/null; }

# After reading ESC, classify the rest as mouse click or CSI (arrows).
# On left-click press: sets MOUSE_X/Y, returns 0.
# On CSI sequence: sets CSI_KEY to e.g. $'\e[A', returns 2.
# On failure: returns 1.
read_esc_sequence() {
    local rest code
    CSI_KEY=""
    IFS= read -rsn1 -t 0.05 rest || return 1
    if [[ "$rest" != "[" ]]; then
        return 1
    fi
    IFS= read -rsn1 -t 0.05 rest || return 1
    if [[ "$rest" == "<" ]]; then
        # SGR mouse: ESC [ < btn ; x ; y M/m
        code=""
        while IFS= read -rsn1 -t 0.05 rest; do
            case "$rest" in
                M|m)
                    MOUSE_RELEASE=0; [[ "$rest" == "m" ]] && MOUSE_RELEASE=1
                    IFS=';' read -r MOUSE_BTN MOUSE_X MOUSE_Y <<< "${code}"
                    (( MOUSE_RELEASE == 0 && MOUSE_BTN == 0 )) && return 0
                    return 1;;
                *) code+="$rest";;
            esac
        done
        return 1
    fi
    # CSI arrow / other: ESC [ rest  (and maybe one more digit for ~)
    CSI_KEY="${ESC}[${rest}"
    if [[ "$rest" =~ [0-9] ]]; then
        IFS= read -rsn1 -t 0.01 rest2 || true
        [[ -n "${rest2:-}" ]] && CSI_KEY+="$rest2"
    fi
    return 2
}

need_sudo() {
    (( EUID == 0 )) && return 0
    if ! sudo -n true 2>/dev/null; then
        printf "  ${FG_YELLOW}🔑${RESET} sudo access needed\n"
        sudo -v || { fail "could not obtain sudo"; return 1; }
    fi
    if [[ -z "$SUDO_KEEPALIVE" ]]; then
        ( while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done ) 2>/dev/null &
        SUDO_KEEPALIVE=$!
    fi
}

cleanup() {
    [[ -n "$SUDO_KEEPALIVE" ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null
    local f; for f in "${FEDUP_TMPFILES[@]+"${FEDUP_TMPFILES[@]}"}"; do rm -f "$f"; done
    mouse_off 2>/dev/null
    tput cnorm 2>/dev/null
}
trap cleanup EXIT

notify() {  # notify "title" "body" [icon]
    command -v notify-send &>/dev/null || return 0
    notify-send -a "fedup" -i "${3:-system-software-update}" "$1" "$2" 2>/dev/null
}

is_dnf5() { dnf --version 2>/dev/null | grep -qi 'dnf5'; }

# Run a command with sudo only when actually mutating (not dry-run, not already root).
# Dry-run previews use plain dnf --assumeno and need no privilege.
priv() {
    if $DRY_RUN || (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

# dnf needs-restarting: exit 1 = action recommended, 0 = clean, other = unavailable.
# dnf5 treats -r/--reboothint as a no-op (bare command == dnf4's -r).
reboot_needed() {
    dnf needs-restarting -r &>/dev/null
    (( $? == 1 ))
}

# List services holding stale libs (dnf4 --services / dnf5 -s|--services).
# Note: needs-restarting exits 1 when services need a restart — that is success for us.
dnf_stale_services() {
    local out=""
    out=$(priv dnf needs-restarting --services 2>/dev/null) || true
    [[ -z "$out" ]] && { out=$(priv dnf needs-restarting -s 2>/dev/null) || true; }
    printf '%s\n' "$out" | grep -E '\.service' || true
}

# Last dnf transaction details for history reports.
dnf_history_last() {
    priv dnf history info last 2>/dev/null \
        || priv dnf history info 2>/dev/null | head -n 80
}

# ───────────────────── Exclude lists & safety gates ───────────────────
# True if package name matches any comma-separated EXCLUDE glob.
pkg_excluded() {
    local name="$1" pat
    [[ -z "$EXCLUDE" ]] && return 1
    local IFS=','
    for pat in $EXCLUDE; do
        pat="${pat// /}"
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2254
        case "$name" in
            $pat) return 0;;
        esac
    done
    return 1
}

# Emit dnf --exclude=… args from EXCLUDE config.
dnf_exclude_args() {
    local pat
    [[ -z "$EXCLUDE" ]] && return 0
    local IFS=','
    for pat in $EXCLUDE; do
        pat="${pat// /}"
        [[ -n "$pat" ]] && printf -- '--exclude=%s\n' "$pat"
    done
}

# Free space on mount for path, in whole GiB (integer).
free_gib() {
    local path="${1:-/}"
    df -BG --output=avail "$path" 2>/dev/null | awk 'NR==2{gsub(/G/,""); print int($1+0)}'
}

# Fail (return 1) if / or /var have less than MIN_FREE_GB free.
disk_preflight() {
    local root_free var_free need="${MIN_FREE_GB:-2}"
    root_free=$(free_gib /)
    var_free=$(free_gib /var)
    [[ -z "$root_free" ]] && root_free=999
    [[ -z "$var_free" ]] && var_free=999
    info "Free space: / ${root_free}G · /var ${var_free}G (need ≥ ${need}G)"
    if (( root_free < need || var_free < need )); then
        fail "Not enough free disk space (need ≥ ${need} GiB on / and /var)."
        warn "Free space or set MIN_FREE_GB lower in $CONFIG_FILE — aborting."
        return 1
    fi
    return 0
}

# True if system is on AC power (or power class unknown / desktop).
on_ac_power() {
    local bat supply online
    # No battery sysfs → treat as desktop / always OK
    shopt -s nullglob
    local bats=(/sys/class/power_supply/BAT*)
    shopt -u nullglob
    (( ${#bats[@]} == 0 )) && return 0
    for supply in /sys/class/power_supply/*; do
        [[ -f "$supply/type" ]] || continue
        [[ $(cat "$supply/type" 2>/dev/null) == "Mains" ]] || continue
        online=$(cat "$supply/online" 2>/dev/null || echo 0)
        (( online == 1 )) && return 0
    done
    # Some systems only expose BAT status
    for bat in "${bats[@]}"; do
        [[ -f "$bat/status" ]] || continue
        [[ $(cat "$bat/status" 2>/dev/null) == "Charging" ]] && return 0
        [[ $(cat "$bat/status" 2>/dev/null) == "Full" ]] && return 0
    done
    return 1
}

battery_preflight() {
    $REQUIRE_AC || return 0
    if on_ac_power; then
        good "AC power detected (REQUIRE_AC=true)."
        return 0
    fi
    fail "On battery power and REQUIRE_AC=true — plug in to continue."
    if confirm "Override and upgrade on battery anyway?"; then
        warn "Proceeding on battery at your own risk."
        return 0
    fi
    return 1
}

# Combined gates for mutating upgrade paths. Returns 1 to abort.
safety_gates() {
    disk_preflight || return 1
    battery_preflight || return 1
    return 0
}

# Human-readable byte size.
human_bytes() {
    local b="${1:-0}"
    if (( b >= 1073741824 )); then
        awk -v b="$b" 'BEGIN{printf "%.1f GiB", b/1073741824}'
    elif (( b >= 1048576 )); then
        awk -v b="$b" 'BEGIN{printf "%.0f MiB", b/1048576}'
    elif (( b >= 1024 )); then
        awk -v b="$b" 'BEGIN{printf "%.0f KiB", b/1024}'
    else
        printf "%s B" "$b"
    fi
}

# Estimate download size for pending (or listed) dnf upgrades. Sets EST_BYTES, EST_HUMAN.
estimate_dnf_size() {
    local bytes=0 out
    # Prefer downloadsize from repoquery --upgrades; fall back to size.
    # repoquery can take a while against large metadata — show progress when interactive.
    if (( $# > 0 )); then
        if _ui_progress; then
            spinner_soft out "Estimating download size ($# package(s))" \
                dnf -q repoquery --qf '%{downloadsize}\n' "$@"
            bytes=$(printf '%s\n' "$out" | awk '{s+=$1} END{print s+0}')
            if [[ -z "$bytes" || "$bytes" == "0" ]]; then
                spinner_soft out "Estimating package size ($# package(s))" \
                    dnf -q repoquery --qf '%{size}\n' "$@"
                bytes=$(printf '%s\n' "$out" | awk '{s+=$1} END{print s+0}')
            fi
        else
            bytes=$(dnf -q repoquery --qf '%{downloadsize}\n' "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}')
            [[ -z "$bytes" || "$bytes" == "0" ]] && \
                bytes=$(dnf -q repoquery --qf '%{size}\n' "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}')
        fi
    else
        if _ui_progress; then
            spinner_soft out "Estimating download size for pending upgrades" \
                dnf -q repoquery --upgrades --qf '%{downloadsize}\n'
            bytes=$(printf '%s\n' "$out" | awk '{s+=$1} END{print s+0}')
            if [[ -z "$bytes" || "$bytes" == "0" ]]; then
                spinner_soft out "Estimating package size for pending upgrades" \
                    dnf -q repoquery --upgrades --qf '%{size}\n'
                bytes=$(printf '%s\n' "$out" | awk '{s+=$1} END{print s+0}')
            fi
        else
            bytes=$(dnf -q repoquery --upgrades --qf '%{downloadsize}\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
            [[ -z "$bytes" || "$bytes" == "0" ]] && \
                bytes=$(dnf -q repoquery --upgrades --qf '%{size}\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
        fi
    fi
    EST_BYTES=${bytes:-0}
    EST_HUMAN=$(human_bytes "$EST_BYTES")
    # Rough time at ~10 MiB/s broadband
    local secs=$(( EST_BYTES / 10485760 ))
    (( secs < 1 && EST_BYTES > 0 )) && secs=1
    if (( EST_BYTES == 0 )); then
        EST_ETA="unknown"
    elif (( secs < 60 )); then
        EST_ETA="~${secs}s"
    else
        EST_ETA="~$(( (secs + 59) / 60 )) min"
    fi
}

show_tx_estimate() {  # optional package list as args
    estimate_dnf_size "$@"
    info "Estimated download: ${FG_CYAN}${EST_HUMAN}${RESET}  ·  rough ETA @10 MiB/s: ${FG_CYAN}${EST_ETA}${RESET}"
    [[ -n "$EXCLUDE" ]] && info "Exclude globs active: ${FG_GRAY}$EXCLUDE${RESET}"
}

# ───────────────────────── History / reporting ────────────────────────
RUN_LOG=""
log_start() {  # log_start "action name"
    RUN_LOG="$HIST_DIR/$(date +%Y-%m-%d_%H%M%S)_${1// /-}.log"
    {
        echo "fedup v$VERSION report — $1"
        echo "host: $(hostname) · kernel: $(uname -r) · date: $(date -R)"
        echo "══════════════════════════════════════════════════════════"
    } > "$RUN_LOG"
}
log_line()  { [[ -n "$RUN_LOG" ]] && echo "$*" >> "$RUN_LOG"; return 0; }

# Progress-spam matcher: fwupd/flatpak/dnf non-TTY output like "Downloading…: 11.5%"
PROGRESS_RE='^[[:space:]]*(Downloading|Decompressing|Writing|Verifying|Waiting|Authenticating|Erasing|Scheduling|Restarting device|Loading|Fetching)[.…]*:?[[:space:]]*([0-9]+([.,][0-9]+)?[[:space:]]*%)?[[:space:]]*$'

scrub_progress() {  # filter stdin: drop progress spam, strip ANSI, dedupe
    tr '\r' '\n' \
    | sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | grep -Ev "$PROGRESS_RE" \
    | awk 'NF' | uniq
}

log_cmd() {  # run command once: compact in-place progress on screen, clean log on disk
    local line rc
    local -a pstat
    # Capture the real command status (stage 0). Temporarily clear pipefail so a
    # failing filter/read loop cannot mask or replace the command's exit code.
    set +o pipefail
    "$@" 2>&1 \
    | tr '\r' '\n' \
    | sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $PROGRESS_RE ]]; then
            printf '\r\033[K  %b  %s %s' \
                "${FG_CYAN}⇣${RESET}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]:-…}"
        elif [[ -n "${line// /}" ]]; then
            printf '\r\033[K  %s\n' "$line"
            log_line "  $line"
        fi
      done
    pstat=("${PIPESTATUS[@]}")
    set -o pipefail
    rc=${pstat[0]:-1}
    printf '\r\033[K'
    return "$rc"
}
log_dnf_tx() {  # append last dnf transaction details
    [[ -n "$RUN_LOG" ]] || return 0
    { echo; echo "── dnf transaction ──"; dnf_history_last; } >> "$RUN_LOG"
}
log_finish() {
    [[ -n "$RUN_LOG" ]] || return 0
    log_line ""
    log_line "finished: $(date -R)"
    info "Report saved: ${FG_GRAY}${RUN_LOG/#$HOME/\~}${RESET}"
    RUN_LOG=""
}

# ───────────────────────── Btrfs snapshots ────────────────────────────
snapshot_pre_update() {  # returns 0 if snapshot made or declined-but-safe to continue
    local fstype; fstype=$(findmnt -no FSTYPE / 2>/dev/null)
    if [[ "$fstype" != "btrfs" ]]; then
        info "Root filesystem is $fstype — snapshotting skipped (Btrfs only)."
        return 0
    fi
    if command -v snapper &>/dev/null && sudo snapper -c root list &>/dev/null; then
        local num
        num=$(sudo snapper -c root create --type pre --print-number \
              --description "fedup pre-update $(date +%F_%H%M)" --cleanup-algorithm number 2>/dev/null)
        if [[ -n "$num" ]]; then
            good "Snapper pre-update snapshot #$num created (config: root)."
            log_line "snapper pre-update snapshot: #$num"
            SNAP_PRE_NUM="$num"
            return 0
        fi
        warn "snapper snapshot failed — continuing without it."
        return 0
    fi
    # No snapper configured — offer raw btrfs snapshot or snapper install
    warn "Btrfs detected but snapper isn't configured."
    if ! $ALWAYS_SNAPSHOT && confirm "Install & configure snapper for automatic pre/post snapshots?"; then
        sudo dnf install -y snapper python3-dnf-plugin-snapper 2>/dev/null || sudo dnf install -y snapper
        sudo snapper -c root create-config / && good "snapper configured for /"
        snapshot_pre_update; return $?
    fi
    if $ALWAYS_SNAPSHOT || confirm "Take a one-off read-only btrfs snapshot of / instead?"; then
        local dest="/.fedup-snapshots"
        sudo mkdir -p "$dest"
        local name="root-$(date +%Y%m%d-%H%M%S)"
        if sudo btrfs subvolume snapshot -r / "$dest/$name" &>/dev/null; then
            good "Snapshot created: $dest/$name"
            log_line "raw btrfs snapshot: $dest/$name"
        else
            warn "Raw snapshot failed (non-subvolume root layout?) — continuing."
        fi
    fi
    return 0
}

snapshot_post_update() {
    [[ -n "$SNAP_PRE_NUM" ]] || return 0
    command -v snapper &>/dev/null || return 0
    sudo snapper -c root create --type post --pre-number "$SNAP_PRE_NUM" \
        --description "fedup post-update" --cleanup-algorithm number &>/dev/null \
        && good "Snapper post-update snapshot linked to #$SNAP_PRE_NUM."
    SNAP_PRE_NUM=""
}

do_snapshots_menu() {
    title "Snapshots (Btrfs / snapper)"
    need_sudo || return 1
    local fstype; fstype=$(findmnt -no FSTYPE /)
    info "Root filesystem: $fstype"
    if command -v snapper &>/dev/null && sudo snapper -c root list &>/dev/null; then
        echo
        sudo snapper -c root list | tail -n 12 | sed 's/^/     /'
        echo
        confirm "Create a manual snapshot now?" && \
            sudo snapper -c root create --description "fedup manual $(date +%F_%H%M)" && \
            good "Snapshot created."
        info "Rollback: boot a snapshot from GRUB, or use menu → Rollback."
        confirm "Open rollback wizard now?" && do_rollback
    else
        snapshot_pre_update
    fi
}

# ───────────────────── Versionlock / hold manager ─────────────────────
ensure_versionlock() {
    dnf versionlock list &>/dev/null && return 0
    warn "versionlock plugin not available."
    if confirm "Install dnf versionlock plugin?"; then
        need_sudo || return 1
        # dnf5: versionlock ships in dnf5-plugins; dnf4: dedicated python plugin
        if is_dnf5; then
            sudo dnf install -y dnf5-plugins \
                || sudo dnf install -y python3-dnf5-plugin-versionlock 2>/dev/null
        else
            sudo dnf install -y python3-dnf-plugin-versionlock \
                || sudo dnf install -y 'dnf-plugins-core' 2>/dev/null
        fi
        dnf versionlock list &>/dev/null
    else
        return 1
    fi
}

do_versionlock() {
    title "Package holds (versionlock)"
    need_sudo || return
    ensure_versionlock || return
    local locks
    locks=$(dnf versionlock list 2>/dev/null | grep -v '^#' | grep -v '^$')
    if [[ -z "$locks" ]]; then
        info "No packages are currently held."
    else
        info "Held packages:"
        printf '%s\n' "$locks" | sed "s/^/       $(printf '%b' "$PIN") /"
    fi
    echo
    printf "  ${FG_GRAY}[a] add hold   [d] delete hold   [x] clear all   [Enter] back${RESET}\n"
    local key; IFS= read -rsn1 key
    case "$key" in
        a)  printf "\n  package name to hold: "; read -r p
            [[ -n "$p" ]] && sudo dnf versionlock add "$p" && good "Held: $p";;
        d)  printf "\n  package name to release: "; read -r p
            [[ -n "$p" ]] && sudo dnf versionlock delete "$p" && good "Released: $p";;
        x)  confirm "Remove ALL holds?" && sudo dnf versionlock clear && good "All holds cleared.";;
    esac
}

# ──────────────────────── Security-only updates ───────────────────────
do_security() {
    title "Security updates"
    guard_atomic || return 1
    # Dry-run previews need no sudo (dnf --assumeno is unprivileged).
    if ! $DRY_RUN; then
        need_sudo || return 1
    fi
    if $DRY_RUN; then
        spinner "Checking security advisories" dnf -q --refresh updateinfo summary --updates \
            || spinner "Checking security advisories" dnf -q --refresh advisory summary
    else
        spinner "Checking security advisories" sudo dnf -q --refresh updateinfo summary --updates \
            || spinner "Checking security advisories" sudo dnf -q --refresh advisory summary
    fi
    echo "  ── advisory summary ──"
    dnf -q updateinfo summary --updates 2>/dev/null | sed 's/^/     /' \
        || dnf -q advisory summary 2>/dev/null | sed 's/^/     /'
    echo
    local seclist=""
    if _ui_progress; then
        spinner_soft seclist "Listing pending security advisories" bash -c '
            o=$(dnf -q updateinfo list --updates --security 2>/dev/null | tail -n +2)
            [[ -z "$o" ]] && o=$(dnf -q advisory list --security --available 2>/dev/null | tail -n +2)
            printf "%s\n" "$o"
        '
    else
        seclist=$(dnf -q updateinfo list --updates --security 2>/dev/null | tail -n +2)
        [[ -z "$seclist" ]] && seclist=$(dnf -q advisory list --security --available 2>/dev/null | tail -n +2)
    fi
    # Drop a trailing blank line from printf
    seclist=$(printf '%s\n' "$seclist" | sed '/^$/d')
    if [[ -z "$seclist" ]]; then
        good "No pending security updates. 🎉"
        return 0
    fi
    info "Pending security updates:"
    printf '%s\n' "$seclist" | awk '{sev=$2; adv=$1; pkg=$3;
        printf "       %-22s %-10s %s\n", adv, sev, pkg}' | head -30
    local n; n=$(printf '%s\n' "$seclist" | wc -l)
    (( n > 30 )) && printf "       ${FG_GRAY}…and %d more${RESET}\n" "$(( n - 30 ))"
    echo
    mapfile -t _ex < <(dnf_exclude_args)
    show_tx_estimate
    if $DRY_RUN; then
        info "Dry-run — transaction preview only (no sudo required):"
        dnf upgrade --security --assumeno "${_ex[@]}"
        return 0
    fi
    if confirm "Apply security updates only ($n advisories)?"; then
        safety_gates || return 1
        log_start "security-updates"
        snapshot_pre_update
        sudo dnf upgrade --security -y "${_ex[@]}" && good "Security updates applied." || fail "dnf reported errors."
        log_dnf_tx; snapshot_post_update; log_finish
        return 0
    fi
    return 1  # user declined
}

# ────────────── DNF updates + interactive picker (v2) ─────────────────
declare -a PKG_NAME PKG_VER PKG_REPO PKG_SEL

fetch_updates() {
    PKG_NAME=(); PKG_VER=(); PKG_REPO=(); PKG_SEL=()
    local out rc=0
    # Dry-run / unprivileged path can refresh without sudo when metadata is readable.
    # Capture output from the same run so we don't silently re-query after the spinner.
    if $DRY_RUN || (( EUID == 0 )); then
        spinner_capture out "Refreshing metadata & checking for updates" \
            dnf -q --refresh check-update
        rc=$?
    else
        spinner_capture out "Refreshing metadata & checking for updates" \
            sudo dnf -q --refresh check-update
        rc=$?
    fi
    if (( rc == 0 )); then return 1; fi
    if (( rc != 100 )); then fail "dnf check-update failed (rc=$rc)"; return 2; fi
    while read -r name ver repo; do
        [[ -z "$name" || "$name" == Obsoleting* ]] && continue
        # Strip arch for exclude matching (kernel.x86_64 → kernel)
        local bare="${name%.*}"
        if pkg_excluded "$name" || pkg_excluded "$bare"; then
            continue
        fi
        PKG_NAME+=("$name"); PKG_VER+=("$ver"); PKG_REPO+=("$repo"); PKG_SEL+=(1)
    done < <(printf '%s\n' "$out" | awk 'NF==3')
    (( ${#PKG_NAME[@]} > 0 ))
}

show_changelog() {  # show_changelog pkgname
    clear
    printf "\n  ${BOLD}${FG_CYAN}Changelog / advisory — %s${RESET}\n" "$1"
    hr
    local out=""
    local pkg="$1"
    # changelog / advisory lookups can block on metadata — keep the UI alive
    if _ui_progress; then
        spinner_soft out "Fetching changelog / advisory for $pkg" bash -c '
            dnf -q changelog --count=3 "$1" 2>/dev/null \
            || dnf -q changelog --count 3 "$1" 2>/dev/null \
            || dnf -q updateinfo info "$1" 2>/dev/null \
            || dnf -q advisory info "$1" 2>/dev/null \
            || dnf -q repoquery --info "$1" 2>/dev/null \
            || dnf -q info "$1" 2>/dev/null
        ' _ "$pkg"
    else
        out=$(
            dnf -q changelog --count=3 "$pkg" 2>/dev/null \
            || dnf -q changelog --count 3 "$pkg" 2>/dev/null \
            || dnf -q updateinfo info "$pkg" 2>/dev/null \
            || dnf -q advisory info "$pkg" 2>/dev/null \
            || dnf -q repoquery --info "$pkg" 2>/dev/null \
            || dnf -q info "$pkg" 2>/dev/null
        )
    fi
    printf '%s\n' "$out" | head -40 | sed 's/^/   /'
    hr
    printf "  ${FG_GRAY}press any key to return…${RESET}"
    IFS= read -rsn1
}

pick_packages() {
    local page=0 per=14 cur=0 key filter="" total
    local list_top  # 1-based screen row of first package line (set each draw)
    local -a VIEW
    build_view() {
        VIEW=()
        local j
        for j in "${!PKG_NAME[@]}"; do
            [[ -z "$filter" || "${PKG_NAME[j],,}" == *"${filter,,}"* ]] && VIEW+=("$j")
        done
        total=${#VIEW[@]}
        (( cur >= total )) && cur=$(( total > 0 ? total - 1 : 0 ))
        page=$(( total > 0 ? cur / per : 0 ))
    }
    build_view
    tput civis 2>/dev/null
    mouse_on
    while true; do
        clear
        # Layout after clear (1-based): blank, title, help, hr → packages at row 5
        #   row 1: leading blank from title printf
        #   row 2: "Select updates…"
        #   row 3: key help
        #   row 4: hr
        #   row 5+: package lines
        list_top=5
        printf "\n  ${BOLD}${FG_CYAN}Select updates${RESET}  ${FG_GRAY}(%d shown / %d total)${RESET}" "$total" "${#PKG_NAME[@]}"
        [[ -n "$filter" ]] && printf "  ${FG_YELLOW}filter: %s${RESET}" "$filter"
        printf "\n  ${FG_GRAY}↑/↓ move · click/space toggle · a all · n none · / filter · c changelog · p pin · Enter apply · q cancel${RESET}\n"
        hr
        if (( total == 0 )); then
            printf "\n     ${FG_GRAY}no packages match '%s' — press / to change the filter${RESET}\n\n" "$filter"
        fi
        local start=$(( page * per )); local end=$(( start + per - 1 ))
        (( end >= total )) && end=$(( total - 1 ))
        local row=0
        for v in $(seq "$start" "$end"); do
            (( total == 0 )) && break
            local i=${VIEW[v]}
            local mark on_mark
            if (( PKG_SEL[i] )); then
                mark="${FG_GREEN}●${RESET}"
                on_mark="●"
            else
                mark="${FG_GRAY}○${RESET}"
                on_mark="○"
            fi
            if (( v == cur )); then
                printf "  ${BG_SEL}${FG_WHITE} %s %-42.42s %-28.28s %-14.14s${RESET}\n" \
                       "$on_mark" "${PKG_NAME[i]}" "${PKG_VER[i]}" "${PKG_REPO[i]}"
            else
                printf "   %b %-42.42s ${FG_GRAY}%-28.28s %-14.14s${RESET}\n" \
                       "$mark" "${PKG_NAME[i]}" "${PKG_VER[i]}" "${PKG_REPO[i]}"
            fi
            (( row++ )) || true
        done
        local selcount=0; for s in "${PKG_SEL[@]}"; do (( selcount += s )); done
        hr
        printf "  ${FG_GREEN}%d selected${RESET} ${FG_GRAY}· page %d/%d · mouse click supported${RESET}\n" \
               "$selcount" "$(( page + 1 ))" "$(( total > 0 ? (total + per - 1) / per : 1 ))"

        IFS= read -rsn1 key
        if [[ "$key" == "$ESC" ]]; then
            read_esc_sequence
            local esc_rc=$?
            if (( esc_rc == 0 )); then
                # Map click Y (1-based) → index on this page
                local click_row=$(( MOUSE_Y - list_top ))
                if (( click_row >= 0 && click_row <= end - start && total > 0 )); then
                    cur=$(( start + click_row ))
                    local ci=${VIEW[cur]}
                    PKG_SEL[ci]=$(( 1 - PKG_SEL[ci] ))
                fi
                continue
            elif (( esc_rc == 2 )); then
                key="$CSI_KEY"
            else
                continue
            fi
        fi
        local ci=-1; (( total > 0 )) && ci=${VIEW[cur]}
        case "$key" in
            "${ESC}[A") (( cur > 0 )) && (( cur-- )); (( cur < page*per )) && (( page-- ));;
            "${ESC}[B") (( cur < total-1 )) && (( cur++ )); (( cur >= (page+1)*per )) && (( page++ ));;
            " ")      (( ci >= 0 )) && PKG_SEL[ci]=$(( 1 - PKG_SEL[ci] ));;
            a)        for v in "${VIEW[@]}"; do PKG_SEL[v]=1; done;;
            n)        for v in "${VIEW[@]}"; do PKG_SEL[v]=0; done;;
            /)        tput cnorm; mouse_off
                      printf "\r\033[K  filter (empty to clear): "
                      read -r filter
                      cur=0; page=0; build_view
                      tput civis 2>/dev/null; mouse_on;;
            c)        (( ci >= 0 )) && { mouse_off; show_changelog "${PKG_NAME[ci]}"; tput civis 2>/dev/null; mouse_on; };;
            p)        if (( ci >= 0 )); then
                          tput cnorm; mouse_off
                          if ensure_versionlock; then
                              sudo dnf versionlock add "${PKG_NAME[ci]}" &>/dev/null \
                                  && PKG_SEL[ci]=0 \
                                  && PKG_REPO[ci]="⚲ held"
                          fi
                          tput civis 2>/dev/null; mouse_on
                      fi;;
            q)        mouse_off; tput cnorm; return 1;;
            "")       mouse_off; tput cnorm; return 0;;
        esac
    done
}

do_dnf_selective() {
    title "System updates (dnf) — pick & choose"
    guard_atomic || return 1
    if ! $DRY_RUN; then
        need_sudo || return 1
    fi
    fetch_updates
    case $? in
        1) good "System is fully up to date — nothing to do."; return 0;;
        2) return 2;;
    esac
    pick_packages || { warn "Selection cancelled."; return 1; }
    local chosen=()
    for i in "${!PKG_NAME[@]}"; do (( PKG_SEL[i] )) && chosen+=("${PKG_NAME[i]}"); done
    clear; banner; title "Applying ${#chosen[@]} selected updates"
    if (( ${#chosen[@]} == 0 )); then warn "Nothing selected."; return 1; fi
    show_tx_estimate "${chosen[@]}"
    mapfile -t _ex < <(dnf_exclude_args)
    if $DRY_RUN; then
        info "Dry-run — transaction preview only (no sudo required):"
        dnf upgrade --assumeno "${_ex[@]}" "${chosen[@]}"
        return 0
    fi
    safety_gates || return 1
    log_start "selective-dnf"
    snapshot_pre_update
    sudo dnf upgrade -y "${_ex[@]}" "${chosen[@]}" && good "Selected packages updated." || fail "dnf upgrade reported errors."
    log_dnf_tx; snapshot_post_update; log_finish
}

do_dnf_full() {
    title "Full system upgrade (dnf)"
    guard_atomic || return 1
    mapfile -t _ex < <(dnf_exclude_args)
    show_tx_estimate
    if $DRY_RUN; then
        info "Dry-run — transaction preview only (no sudo required):"
        dnf upgrade --refresh --assumeno "${_ex[@]}"
        return 0
    fi
    need_sudo || return 1
    safety_gates || return 1
    log_start "full-dnf"
    snapshot_pre_update
    sudo dnf upgrade --refresh -y "${_ex[@]}" && good "System packages updated." || fail "dnf upgrade reported errors."
    log_dnf_tx; snapshot_post_update; log_finish
}

# ─────────────────────────── Mirror tuning ────────────────────────────
do_mirrors() {
    title "Mirror & download tuning"
    guard_atomic || return
    need_sudo || return
    local conf=/etc/dnf/dnf.conf
    info "Current settings in $conf:"
    grep -E 'fastest_mirror|max_parallel_downloads|countme' "$conf" 2>/dev/null | sed 's/^/       /' \
        || printf "       ${FG_GRAY}(defaults)${RESET}\n"
    echo
    if confirm "Enable fastest_mirror + 10 parallel downloads?"; then
        sudo touch "$conf"
        grep -q '^fastest_mirror' "$conf" \
            && sudo sed -i 's/^fastest_mirror.*/fastest_mirror=True/' "$conf" \
            || echo 'fastest_mirror=True' | sudo tee -a "$conf" >/dev/null
        grep -q '^max_parallel_downloads' "$conf" \
            && sudo sed -i 's/^max_parallel_downloads.*/max_parallel_downloads=10/' "$conf" \
            || echo 'max_parallel_downloads=10' | sudo tee -a "$conf" >/dev/null
        good "dnf will now benchmark mirrors and pick the fastest."
    fi
    if confirm "Clear metadata cache and re-resolve mirrors now?"; then
        spinner "Rebuilding dnf cache from best mirrors" sudo dnf clean expire-cache
        spinner "Downloading fresh metadata" sudo dnf -q makecache
    fi
}

# ─────────────────────────────── Flatpak ──────────────────────────────
declare -a FP_ID FP_VER FP_SEL

fetch_flatpak_updates() {
    FP_ID=(); FP_VER=(); FP_SEL=()
    local app ver out=""
    if _ui_progress; then
        spinner_soft out "flatpak: checking for updates" \
            flatpak remote-ls --updates --columns=application,version
    else
        out=$(flatpak remote-ls --updates --columns=application,version 2>/dev/null)
    fi
    while IFS=$'\t' read -r app ver; do
        [[ -z "$app" ]] && continue
        FP_ID+=("$app"); FP_VER+=("${ver:-?}"); FP_SEL+=(1)
    done < <(printf '%s\n' "$out" | awk -F'\t' 'NF{print}')
    # Fallback when columns aren't tab-separated
    if (( ${#FP_ID[@]} == 0 )); then
        while read -r app ver _; do
            [[ -z "$app" || "$app" == Application ]] && continue
            FP_ID+=("$app"); FP_VER+=("${ver:-?}"); FP_SEL+=(1)
        done < <(printf '%s\n' "$out")
    fi
    (( ${#FP_ID[@]} > 0 ))
}

pick_flatpaks() {
    # Reuse package picker arrays interface with flatpak data
    PKG_NAME=("${FP_ID[@]}"); PKG_VER=("${FP_VER[@]}")
    PKG_REPO=(); local i
    for i in "${!FP_ID[@]}"; do PKG_REPO+=("flatpak"); done
    PKG_SEL=("${FP_SEL[@]}")
    pick_packages || return 1
    FP_SEL=("${PKG_SEL[@]}")
    return 0
}

do_flatpak() {
    title "Flatpak / Flathub"
    if ! command -v flatpak &>/dev/null; then
        warn "flatpak is not installed."
        confirm "Install flatpak now?" && { need_sudo && sudo dnf install -y flatpak; } || return 1
    fi
    if ! flatpak remotes | grep -qi flathub; then
        confirm "Flathub remote missing — add it?" && \
            flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    fi
    if ! fetch_flatpak_updates; then
        good "All Flatpaks are current."
        confirm "Remove unused Flatpak runtimes?" && run flatpak uninstall --unused -y
        return 0
    fi
    info "${#FP_ID[@]} Flatpak update(s) available — pick which to apply."
    if ! pick_flatpaks; then warn "Selection cancelled."; return 1; fi
    local chosen=() i
    for i in "${!FP_ID[@]}"; do (( FP_SEL[i] )) && chosen+=("${FP_ID[i]}"); done
    if (( ${#chosen[@]} == 0 )); then warn "Nothing selected."; return 1; fi
    clear; banner; title "Updating ${#chosen[@]} Flatpak(s)"
    if $DRY_RUN; then
        for i in "${chosen[@]}"; do run flatpak update -y "$i"; done
        return 0
    fi
    if confirm "Update ${#chosen[@]} selected Flatpak(s)?"; then
        log_start "flatpak-selective"
        for i in "${chosen[@]}"; do
            run log_cmd flatpak update -y "$i" && good "Updated $i" || warn "Failed: $i"
        done
        log_finish
    else
        return 1
    fi
    confirm "Remove unused Flatpak runtimes?" && run flatpak uninstall --unused -y
}

# ──────────────────────────────── Snap ────────────────────────────────
do_snap() {
    title "Snap"
    if ! command -v snap &>/dev/null; then
        warn "snapd is not installed."
        if confirm "Install snapd (with classic-snap symlink)?"; then
            need_sudo || return
            sudo dnf install -y snapd && sudo ln -sf /var/lib/snapd/snap /snap
            warn "Log out/in (or reboot) once so snap paths land, then rerun."
        fi
        return
    fi
    need_sudo || return
    local list out=""
    if _ui_progress; then
        spinner_soft out "snap: checking for updates" snap refresh --list
        list=$(printf '%s\n' "$out" | tail -n +2)
    else
        list=$(snap refresh --list 2>/dev/null | tail -n +2)
    fi
    # Drop empty lines so "all current" is reliable
    list=$(printf '%s\n' "$list" | sed '/^$/d')
    if [[ -z "$list" ]]; then
        good "All snaps are current."
    else
        info "Snap updates available:"; printf '%s\n' "$list" | sed 's/^/       /'
        echo
        if confirm "Refresh all snaps?"; then
            log_start "snap"
            run log_cmd sudo snap refresh && good "Snaps refreshed."
            log_finish
        fi
    fi
}

# ─────────────────────────────── Codecs ───────────────────────────────
do_codecs() {
    title "Third-party codecs (RPM Fusion)"
    guard_atomic || return
    need_sudo || return
    local rel; rel=$(rpm -E %fedora)
    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        if confirm "RPM Fusion (free + nonfree) not enabled — enable it?"; then
            sudo dnf install -y \
              "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
              "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm" \
              && good "RPM Fusion enabled."
        else
            return
        fi
    else
        good "RPM Fusion is already enabled."
    fi
    if confirm "Swap in full ffmpeg + update multimedia group (H.264/H.265/AAC…)?"; then
        run sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
        run sudo dnf update -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
        good "Multimedia codecs installed/updated."
    fi
    if confirm "Also install Intel/AMD VA-API hardware decode drivers?"; then
        if lspci | grep -qi 'vga.*intel'; then run sudo dnf install -y intel-media-driver; fi
        if lspci | grep -qi 'vga.*\(amd\|ati\)'; then
            run sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld
            run sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
        fi
        good "Hardware acceleration drivers handled."
    fi
}

# ────────────────────────────── Firmware ──────────────────────────────
do_firmware() {
    title "Device firmware (fwupd)"
    if ! command -v fwupdmgr &>/dev/null; then
        confirm "fwupd not installed — install it?" && { need_sudo && sudo dnf install -y fwupd; } || return
    fi
    spinner "Refreshing LVFS firmware metadata" fwupdmgr refresh --force
    local updates=""
    if _ui_progress; then
        spinner_soft updates "firmware: checking devices for updates" fwupdmgr get-updates
    else
        updates=$(fwupdmgr get-updates 2>/dev/null)
    fi
    if [[ -z "$updates" ]] || grep -qi 'no updat' <<< "$updates"; then
        good "All device firmware is current."
        return
    fi
    info "Firmware updates available:"
    printf '%s\n' "$updates" | sed 's/^/     /' | head -30
    echo
    warn "Firmware flashes are applied at next reboot — don't power off mid-flash."
    if confirm "Download & stage firmware updates now?"; then
        log_start "firmware"
        run log_cmd fwupdmgr update -y
        log_finish
        good "Firmware staged. Reboot when convenient to apply."
    fi
}

# ──────────────── Service restarts (avoid full reboots) ───────────────
do_restarting() {
    title "Stale libraries — reboot or restart services?"
    need_sudo || return 1
    # dnf4/dnf5: exit 1 = reboot recommended; 0 = clean; other = plugin missing
    local tmp_svcs nrc
    tmp_svcs=$(mktemp "${TMPDIR:-/tmp}/fedup_svcs.XXXXXX") || tmp_svcs=$(mktemp)
    FEDUP_TMPFILES+=("$tmp_svcs")
    # needs-restarting can take a while — animate while both checks run
    if _ui_progress; then
        spinner "Checking reboot hint & services with stale libraries" bash -c '
            if dnf needs-restarting -r &>/dev/null; then
                echo 0 > "$1.rc"
            else
                echo $? > "$1.rc"
            fi
            # Mirror dnf_stale_services / priv: sudo when not root
            if (( EUID == 0 )); then
                out=$(dnf needs-restarting --services 2>/dev/null) || true
                [[ -z "$out" ]] && out=$(dnf needs-restarting -s 2>/dev/null) || true
            else
                out=$(sudo dnf needs-restarting --services 2>/dev/null) || true
                [[ -z "$out" ]] && out=$(sudo dnf needs-restarting -s 2>/dev/null) || true
            fi
            printf "%s\n" "$out" | sed "/^$/d" > "$1"
        ' _ "$tmp_svcs"
        nrc=$(cat "$tmp_svcs.rc" 2>/dev/null || echo 2)
        FEDUP_TMPFILES+=("$tmp_svcs.rc")
    else
        if reboot_needed; then nrc=1
        else
            dnf needs-restarting -r &>/dev/null
            nrc=$?
        fi
        dnf_stale_services > "$tmp_svcs"
    fi
    if (( nrc == 1 )); then
        warn "Kernel or core libraries changed — a full reboot IS recommended."
    elif (( nrc == 0 )); then
        good "Core system is clean — no reboot required."
    else
        warn "needs-restarting unavailable (install dnf5-plugins / dnf-plugins-core) — cannot assess reboot."
    fi
    echo
    local svcs
    svcs=$(cat "$tmp_svcs" 2>/dev/null)
    rm -f "$tmp_svcs" "$tmp_svcs.rc"
    if [[ -z "$svcs" ]]; then
        good "No running services are holding deleted/updated libraries."
        return 0
    fi
    info "Services running with stale libraries:"
    printf '%s\n' "$svcs" | sed 's/^/       ↻ /'
    echo
    if confirm "Restart ALL of these services in place?"; then
        while read -r s; do
            [[ -z "$s" ]] && continue
            sudo systemctl try-restart "$s" &>/dev/null \
                && printf "       ${OK} restarted %s\n" "$s" \
                || printf "       ${WARN} skipped   %s\n" "$s"
        done <<< "$svcs"
        good "Done — many reboots avoided this way."
        return 0
    fi
    return 1
}

# ───────────────── Distrobox / Toolbox containers ─────────────────────
do_containers() {
    title "Container updates (distrobox / toolbox)"
    local found=0
    if command -v distrobox &>/dev/null; then
        found=1
        local boxes; boxes=$(distrobox list --no-color 2>/dev/null | tail -n +2 | awk -F'|' '{gsub(/ /,"",$2); print $2}')
        if [[ -z "$boxes" ]]; then
            info "No distrobox containers found."
        else
            info "Distrobox containers: $(tr '\n' ' ' <<< "$boxes")"
            confirm "Upgrade ALL distrobox containers?" && distrobox upgrade --all
        fi
    fi
    if command -v toolbox &>/dev/null; then
        found=1
        local tboxes; tboxes=$(toolbox list -c 2>/dev/null | tail -n +2 | awk '{print $2}')
        if [[ -z "$tboxes" ]]; then
            info "No toolbox containers found."
        else
            for t in $tboxes; do
                confirm "Update toolbox '$t'?" && toolbox run -c "$t" sudo dnf upgrade -y
            done
        fi
    fi
    (( found )) || info "Neither distrobox nor toolbox is installed — nothing to do."
}

# ───────────────────────── COPR health check ──────────────────────────
do_copr_health() {
    title "COPR repo health check"
    local repos rel arch
    rel=$(rpm -E %fedora); arch=$(uname -m)
    repos=$(grep -l 'copr' /etc/yum.repos.d/*.repo 2>/dev/null)
    if [[ -z "$repos" ]]; then
        good "No COPR repos enabled — nothing to check."
        return
    fi
    info "Probing each enabled COPR (network check, up to ~8s each)…"
    for f in $repos; do
        local name enabled url
        name=$(grep -m1 '^\[' "$f" | tr -d '[]')
        enabled=$(grep -m1 '^enabled' "$f" | grep -o '[01]')
        url=$(grep -m1 '^baseurl' "$f" | cut -d= -f2- | sed "s/\$releasever/$rel/g; s/\$basearch/$arch/g" | tr -d ' ')
        if [[ "$enabled" != "1" ]]; then
            printf "  ${FG_GRAY}−  %s (disabled)${RESET}\n" "$name"
            continue
        fi
        # Live feedback: which repo is being probed right now
        printf "  ${FG_CYAN}·${RESET}  checking %s…" "$name"
        if [[ -n "$url" ]] && curl -sfIL --max-time 8 "${url%/}/repodata/repomd.xml" &>/dev/null; then
            printf "\r  ${OK}  %s   \n" "$name"
        else
            printf "\r  ${ERR}  %s  ${FG_RED}← unreachable for Fedora %s (dead/abandoned COPR?)${RESET}\n" "$name" "$rel"
            if confirm "   Disable this repo?"; then
                # dnf5: config-manager disable / setopt; dnf4: --set-disabled
                sudo dnf config-manager disable "$name" 2>/dev/null \
                    || sudo dnf config-manager setopt "${name}.enabled=0" 2>/dev/null \
                    || sudo dnf config-manager --set-disabled "$name" 2>/dev/null \
                    && good "Disabled $name" || warn "Could not disable $name"
            fi
        fi
    done
    info "Dead COPRs are the #1 cause of dnf errors after a Fedora version bump."
}

# ─────────────────────────── Check / counts ───────────────────────────
# Trim wc -l whitespace so arithmetic stays clean.
_count_trim() { local v="$1"; v="${v//[[:space:]]/}"; printf '%s' "${v:-0}"; }

count_updates() {  # sets CNT_DNF CNT_SEC CNT_FLATPAK CNT_SNAP CNT_FW REBOOT CNT_TOTAL
    # Honors SKIP_* config so --check / notifications match 'update everything'.
    CNT_DNF=0; CNT_SEC=0; CNT_FLATPAK=0; CNT_SNAP=0; CNT_FW=0; REBOOT=false
    local show_prog=false out rc sec_out
    _ui_progress && show_prog=true

    # ── dnf (metadata refresh is usually the slowest step) ──
    rc=0
    if $show_prog; then
        # Keep real rc (100 = updates available) so counts stay accurate
        spinner_capture out "dnf: refreshing metadata & counting updates" \
            dnf -q check-update --refresh
        rc=$?
    else
        out=$(dnf -q check-update --refresh 2>/dev/null) || rc=$?
    fi
    if (( rc == 100 )); then
        CNT_DNF=$(_count_trim "$(printf '%s\n' "$out" | awk 'NF==3' | grep -vc '^Obsoleting' || true)")
    fi

    # Security advisories (usually quick after the refresh above)
    if $show_prog; then
        spinner_soft out "dnf: counting security advisories" bash -c '
            o=$(dnf -q updateinfo list --updates --security 2>/dev/null | tail -n +2)
            [[ -z "$o" ]] && o=$(dnf -q advisory list --security --available 2>/dev/null | tail -n +2)
            printf "%s\n" "$o"
        '
        sec_out=$out
    else
        sec_out=$(dnf -q updateinfo list --updates --security 2>/dev/null | tail -n +2)
        # dnf5: updateinfo is an alias for advisory; keep both for older/plugin edge cases
        [[ -z "$sec_out" ]] && sec_out=$(dnf -q advisory list --security --available 2>/dev/null | tail -n +2)
    fi
    CNT_SEC=$(_count_trim "$(printf '%s\n' "$sec_out" | grep -c . || true)")

    # ── flatpak ──
    if ! $SKIP_FLATPAK && command -v flatpak &>/dev/null; then
        if $show_prog; then
            spinner_soft out "flatpak: checking for updates" flatpak remote-ls --updates
            CNT_FLATPAK=$(_count_trim "$(printf '%s\n' "$out" | grep -c . || true)")
        else
            CNT_FLATPAK=$(_count_trim "$(flatpak remote-ls --updates 2>/dev/null | wc -l)")
        fi
    elif $show_prog && $SKIP_FLATPAK; then
        info "flatpak: skipped (SKIP_FLATPAK=true)"
    fi

    # ── snap ──
    if ! $SKIP_SNAP && command -v snap &>/dev/null; then
        if $show_prog; then
            spinner_soft out "snap: checking for updates" snap refresh --list
            CNT_SNAP=$(_count_trim "$(printf '%s\n' "$out" | tail -n +2 | grep -c . || true)")
        else
            CNT_SNAP=$(_count_trim "$(snap refresh --list 2>/dev/null | tail -n +2 | wc -l)")
        fi
    elif $show_prog && $SKIP_SNAP; then
        info "snap: skipped (SKIP_SNAP=true)"
    fi

    # ── firmware ──
    if ! $SKIP_FIRMWARE && command -v fwupdmgr &>/dev/null; then
        if $show_prog; then
            spinner_soft out "firmware: checking LVFS for updates" fwupdmgr get-updates
            CNT_FW=$(_count_trim "$(printf '%s\n' "$out" | grep -c 'New version' || true)")
        else
            out=$(fwupdmgr get-updates 2>/dev/null) && \
                CNT_FW=$(_count_trim "$(printf '%s\n' "$out" | grep -c 'New version' || true)")
        fi
    elif $show_prog && $SKIP_FIRMWARE; then
        info "firmware: skipped (SKIP_FIRMWARE=true)"
    fi

    if $show_prog; then
        # needs-restarting exits 1 when a reboot is recommended — not an error
        printf "  ${FG_CYAN}·${RESET}  checking whether a reboot is pending…"
        if reboot_needed; then
            REBOOT=true
            printf "\r  ${WARN}  reboot is pending from a previous update   \n"
        else
            printf "\r  ${OK}  no reboot pending   \n"
        fi
    else
        reboot_needed && REBOOT=true
    fi

    CNT_TOTAL=$(( CNT_DNF + CNT_FLATPAK + CNT_SNAP + CNT_FW ))
}

do_check() {  # $1 = "notify" to send desktop notification, JSON handled by caller
    if $JSON_OUT; then
        count_updates
        printf '{"host":"%s","dnf":%d,"security":%d,"flatpak":%d,"snap":%d,"firmware":%d,"total":%d,"reboot_needed":%s}\n' \
            "$(hostname)" "$CNT_DNF" "$CNT_SEC" "$CNT_FLATPAK" "$CNT_SNAP" "$CNT_FW" "$CNT_TOTAL" "$REBOOT"
    else
        # Title first so the UI isn't a blank hang while network checks run
        title "Pending updates on $(hostname)"
        info "Querying package sources — this can take a minute…"
        echo
        count_updates
        echo
        printf "     dnf packages : %s%d%s   (security: %s%d%s)\n" "$FG_CYAN" "$CNT_DNF" "$RESET" "$FG_RED" "$CNT_SEC" "$RESET"
        printf "     flatpak      : %s%d%s\n" "$FG_CYAN" "$CNT_FLATPAK" "$RESET"
        printf "     snap         : %s%d%s\n" "$FG_CYAN" "$CNT_SNAP" "$RESET"
        printf "     firmware     : %s%d%s\n" "$FG_CYAN" "$CNT_FW" "$RESET"
        $REBOOT && warn "reboot pending from a previous update"
        if (( CNT_TOTAL == 0 )); then
            good "Nothing pending. You're up to date. 🎉"
        else
            info "Total: ${FG_CYAN}${CNT_TOTAL}${RESET} update(s) across enabled sources"
        fi
    fi
    if [[ "$1" == "notify" ]] && (( CNT_TOTAL > 0 )); then
        local body="$CNT_DNF dnf"
        (( CNT_SEC )) && body+=" ($CNT_SEC security)"
        (( CNT_FLATPAK )) && body+=" · $CNT_FLATPAK flatpak"
        (( CNT_SNAP )) && body+=" · $CNT_SNAP snap"
        (( CNT_FW )) && body+=" · $CNT_FW firmware"
        notify "Updates available" "$body"
    fi
    (( CNT_TOTAL > 0 )) && return 10 || return 0
}

# ───────────────────── systemd timer installation ─────────────────────
do_timers() {
    title "Scheduled checks & auto-updates (systemd timers)"
    local bin="$HOME/.local/bin/fedup"
    info "1) Daily check timer (user) — desktop notification when updates exist"
    info "2) Weekly auto-update timer (system) — runs 'fedup --all' unattended"
    echo
    if confirm "Install DAILY user check timer (notification only)?"; then
        mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
        cp -f "$(readlink -f "$0")" "$bin" && chmod +x "$bin"
        cat > "$HOME/.config/systemd/user/fedup-check.service" <<EOF
[Unit]
Description=fedup — check for pending updates

[Service]
Type=oneshot
SuccessExitStatus=10
ExecStart=$bin --check --notify
EOF
        cat > "$HOME/.config/systemd/user/fedup-check.timer" <<EOF
[Unit]
Description=Daily fedup update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now fedup-check.timer
        good "Daily check timer active:  systemctl --user list-timers fedup-check.timer"
    fi
    echo
    if confirm "Install WEEKLY system auto-update timer (runs as root, unattended)?"; then
        need_sudo || return
        sudo cp -f "$(readlink -f "$0")" /usr/local/bin/fedup && sudo chmod +x /usr/local/bin/fedup
        sudo tee /etc/systemd/system/fedup-auto.service >/dev/null <<'EOF'
[Unit]
Description=fedup — unattended full update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fedup --all
EOF
        sudo tee /etc/systemd/system/fedup-auto.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly fedup auto-update

[Timer]
OnCalendar=Sun 04:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now fedup-auto.timer
        good "Weekly auto-update timer active (Sundays ~4 AM)."
        info "Disable anytime:  sudo systemctl disable --now fedup-auto.timer"
    fi
}

# ───────────────────────────── Remote mode ────────────────────────────
# Run fedup on a remote host, always removing the uploaded copy afterwards.
_remote_ssh() {  # _remote_ssh host remote_path args...
    local host="$1" rpath="$2"; shift 2
    # trap cleans the script even if bash is killed mid-run
    ssh -t "$host" "trap 'rm -f $(printf %q "$rpath")' EXIT; bash $(printf %q "$rpath") $(printf '%q ' "$@")"
}

_remote_ssh_capture() {  # same without -t; stdout captured by caller
    local host="$1" rpath="$2"; shift 2
    ssh "$host" "trap 'rm -f $(printf %q "$rpath")' EXIT; bash $(printf %q "$rpath") $(printf '%q ' "$@")"
}

do_remote() {  # do_remote all|check host1 host2...
    local mode="$1"; shift
    local self; self=$(readlink -f "$0")
    local failures=0 results=()
    for host in "$@"; do
        $JSON_OUT || title "Remote: $host"
        # Unique path avoids clobbering concurrent runs; cleaned via remote trap.
        local rpath="/tmp/fedup.$$.$RANDOM.sh"
        if $DRY_RUN && [[ "$mode" != "check" ]]; then
            printf "  \033[38;5;221m▷ dry-run:\033[0m scp %s %s:%s\n" "$self" "$host" "$rpath"
            printf "  \033[38;5;221m▷ dry-run:\033[0m ssh %s 'bash %s --dry-run --all' (then rm)\n" "$host" "$rpath"
            results+=("{\"host\":\"$host\",\"mode\":\"all\",\"ok\":true,\"dry_run\":true}")
            continue
        fi
        if ! scp -q "$self" "$host:$rpath" 2>/dev/null; then
            $JSON_OUT && results+=("{\"host\":\"$host\",\"mode\":\"$mode\",\"ok\":false,\"error\":\"scp_failed\"}") \
                      || fail "$host — SSH/scp failed (check keys & connectivity)"
            (( failures++ )); continue
        fi
        if [[ "$mode" == "check" ]]; then
            local out rc
            out=$(_remote_ssh_capture "$host" "$rpath" --check --json 2>/dev/null); rc=$?
            # If capture failed before trap, best-effort remote cleanup
            (( rc != 0 && rc != 10 )) && ssh "$host" "rm -f $(printf %q "$rpath")" 2>/dev/null || true
            if [[ -n "$out" ]] && (( rc == 0 || rc == 10 )); then
                $JSON_OUT && results+=("$out") || printf '%s\n' "$out"
            else
                $JSON_OUT && results+=("{\"host\":\"$host\",\"mode\":\"check\",\"ok\":false,\"error\":\"remote_failed\",\"rc\":$rc}") \
                          || fail "$host — remote check failed (rc=$rc)"
                (( failures++ ))
            fi
        else
            if _remote_ssh "$host" "$rpath" --all; then
                $JSON_OUT && results+=("{\"host\":\"$host\",\"mode\":\"all\",\"ok\":true}") \
                          || good "$host — update complete"
            else
                ssh "$host" "rm -f $(printf %q "$rpath")" 2>/dev/null || true
                $JSON_OUT && results+=("{\"host\":\"$host\",\"mode\":\"all\",\"ok\":false}") \
                          || fail "$host — remote update reported errors"
                (( failures++ ))
            fi
        fi
    done
    if $JSON_OUT; then
        printf '['; local first=true
        for r in "${results[@]}"; do $first || printf ','; printf '%s' "$r"; first=false; done
        printf ']\n'
    fi
    (( failures == 0 )) && return 0 || return 1
}

# ───────────────────────────── Everything ─────────────────────────────
do_everything() {
    title "Update everything"
    mapfile -t _ex < <(dnf_exclude_args)
    show_tx_estimate
    if ! $DRY_RUN; then
        need_sudo || return 1
        safety_gates || return 1
    fi
    if $DRY_RUN; then
        info "Dry-run — this is what an 'update everything' run would do:"
        count_updates
        printf "     dnf: %d pkgs (%d security) · flatpak: %d · snap: %d · firmware: %d\n" \
               "$CNT_DNF" "$CNT_SEC" "$CNT_FLATPAK" "$CNT_SNAP" "$CNT_FW"
        [[ -n "$EXCLUDE" ]] && info "EXCLUDE=$EXCLUDE"
        if $IS_ATOMIC; then
            run sudo rpm-ostree upgrade
        else
            run dnf upgrade --refresh --assumeno "${_ex[@]}"
        fi
        $SKIP_FLATPAK    || run flatpak update -y --noninteractive
        $SKIP_SNAP       || run sudo snap refresh
        $SKIP_FIRMWARE   || run fwupdmgr update -y --no-reboot-check
        if ! $SKIP_CONTAINERS; then
            command -v distrobox &>/dev/null && run distrobox upgrade --all
            if command -v toolbox &>/dev/null; then
                local tboxes t
                tboxes=$(toolbox list -c 2>/dev/null | tail -n +2 | awk '{print $2}')
                for t in $tboxes; do
                    run toolbox run -c "$t" sudo dnf upgrade -y
                done
            fi
        fi
        if ! $SKIP_USERSPACE; then
            command -v cargo &>/dev/null && cargo install-update --version &>/dev/null && run cargo install-update -a
            command -v pipx &>/dev/null && run pipx upgrade-all
            command -v npm &>/dev/null && run npm update -g
            command -v brew &>/dev/null && { run brew update; run brew upgrade; }
        fi
        ! $IS_ATOMIC && $AUTOREMOVE && run dnf autoremove --assumeno
        return 0
    fi
    log_start "everything"
    snapshot_pre_update
    local failures=0
    if $IS_ATOMIC; then
        spinner "rpm-ostree: upgrading base image" sudo rpm-ostree upgrade || (( failures++ )) || true
    else
        spinner "dnf: full system upgrade" sudo dnf upgrade --refresh -y "${_ex[@]}" || (( failures++ )) || true
        log_dnf_tx
    fi
    if ! $SKIP_FLATPAK && command -v flatpak &>/dev/null; then
        spinner "flatpak: updating apps & runtimes" flatpak update -y --noninteractive || (( failures++ )) || true
    fi
    if ! $SKIP_SNAP && command -v snap &>/dev/null; then
        spinner "snap: refreshing" sudo snap refresh || (( failures++ )) || true
    fi
    if ! $SKIP_FIRMWARE && command -v fwupdmgr &>/dev/null; then
        spinner "firmware: refreshing LVFS metadata" fwupdmgr refresh --force || (( failures++ )) || true
        if fwupdmgr get-updates &>/dev/null; then
            spinner "firmware: staging updates" fwupdmgr update -y --no-reboot-check || (( failures++ )) || true
        fi
    fi
    if ! $SKIP_CONTAINERS; then
        if command -v distrobox &>/dev/null; then
            spinner "distrobox: upgrading containers" distrobox upgrade --all || (( failures++ )) || true
        fi
        if command -v toolbox &>/dev/null; then
            local tboxes t
            tboxes=$(toolbox list -c 2>/dev/null | tail -n +2 | awk '{print $2}')
            for t in $tboxes; do
                [[ -z "$t" ]] && continue
                spinner "toolbox: upgrading $t" toolbox run -c "$t" sudo dnf upgrade -y || (( failures++ )) || true
            done
        fi
    fi
    if ! $SKIP_USERSPACE; then
        if command -v cargo &>/dev/null && cargo install-update --version &>/dev/null; then
            spinner "cargo: install-update -a" cargo install-update -a || (( failures++ )) || true
        fi
        if command -v pipx &>/dev/null; then
            spinner "pipx: upgrade-all" pipx upgrade-all || (( failures++ )) || true
        fi
        if command -v npm &>/dev/null; then
            spinner "npm: update -g" npm update -g || (( failures++ )) || true
        fi
        if command -v brew &>/dev/null; then
            spinner "brew: update" brew update || (( failures++ )) || true
            spinner "brew: upgrade" brew upgrade || (( failures++ )) || true
        fi
    fi
    if ! $IS_ATOMIC && $AUTOREMOVE; then
        spinner "dnf: cleaning old packages" sudo dnf autoremove -y || (( failures++ )) || true
    fi
    snapshot_post_update
    (( failures > 0 )) && log_line "failures: $failures"
    log_finish
    echo
    if (( failures > 0 )); then
        warn "Finished with $failures failed step(s) — check the log above / history report."
        notify "fedup complete" "Finished with $failures error(s) — review the report" "dialog-warning"
        return 1
    fi
    if reboot_needed; then
        warn "All done — a reboot is recommended (kernel/core libs changed)."
        notify "fedup complete" "Updates applied — reboot recommended" "system-reboot"
    else
        good "All done — no reboot required."
        notify "fedup complete" "All updates applied — no reboot needed"
    fi
    return 0
}

# ──────────────────── User-space package sources ──────────────────────
do_userspace() {
    title "User-space updaters (cargo · pipx · npm · brew · AppImage)"
    info "Opt-in sources — skipped by default in --all (SKIP_USERSPACE=$SKIP_USERSPACE)."
    local found=0

    if command -v cargo &>/dev/null; then
        found=1
        if cargo install-update --version &>/dev/null; then
            info "cargo-update available."
            confirm "Update all cargo-installed binaries?" && \
                run cargo install-update -a
        else
            warn "cargo found but cargo-update is not installed."
            confirm "Install cargo-update (cargo install cargo-update)?" && \
                run cargo install cargo-update
        fi
    fi

    if command -v pipx &>/dev/null; then
        found=1
        confirm "pipx upgrade-all?" && run pipx upgrade-all
    fi

    if command -v npm &>/dev/null; then
        found=1
        confirm "npm update -g (global packages)?" && run npm update -g
    fi

    if command -v brew &>/dev/null; then
        found=1
        confirm "brew update && brew upgrade?" && {
            run brew update
            run brew upgrade
        }
    fi

    # AppImages: update via appimageupdatetool when present
    local dir tool apps=()
    tool=$(command -v appimageupdatetool || command -v appimage-update || true)
    local IFS=':'
    for dir in $APPIMAGE_DIRS; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do apps+=("$f"); done \
            < <(find "$dir" -maxdepth 2 -type f -iname '*.AppImage' -print0 2>/dev/null)
    done
    unset IFS
    if (( ${#apps[@]} > 0 )); then
        found=1
        info "Found ${#apps[@]} AppImage(s) under APPIMAGE_DIRS."
        printf '       %s\n' "${apps[@]}" | head -20
        if [[ -n "$tool" ]]; then
            if confirm "Run $tool on each AppImage?"; then
                local a
                for a in "${apps[@]}"; do
                    run "$tool" -O "$a" || run "$tool" "$a" || warn "Update failed: $a"
                done
            fi
        else
            warn "Install appimageupdatetool for automatic AppImage updates."
        fi
    fi

    (( found )) || info "No user-space package managers detected (cargo/pipx/npm/brew/AppImage)."
}

# ────────────────────────── Kernel cleanup ────────────────────────────
do_kernel_cleanup() {
    title "Kernel cleanup"
    guard_atomic || return 1
    need_sudo || return 1
    local keep="${KERNEL_KEEP:-2}" running
    running=$(uname -r)
    info "Running kernel: $running · keep $keep newest (+ always keep running)"
    # Sort by install time; format: timestamp name
    local list
    list=$(rpm -q kernel-core --qf '%{INSTALLTIME} %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -n)
    if [[ -z "$list" ]]; then
        # Fallback for older layouts
        list=$(rpm -q kernel --qf '%{INSTALLTIME} %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -n)
    fi
    if [[ -z "$list" ]]; then
        warn "No kernel packages found via rpm."
        return 0
    fi
    echo "  Installed kernels (oldest → newest):"
    printf '%s\n' "$list" | awk '{print "       "$2}' 
    local -a all=() remove=()
    while read -r _ts name; do
        [[ -n "$name" ]] && all+=("$name")
    done <<< "$list"
    local n=${#all[@]} i start
    # Keep the last $keep entries
    start=0
    local keep_count=$keep
    (( keep_count < 1 )) && keep_count=1
    local remove_end=$(( n - keep_count ))
    (( remove_end < 0 )) && remove_end=0
    for (( i=0; i<remove_end; i++ )); do
        local pkg="${all[i]}"
        # Never remove the running kernel package
        if [[ "$pkg" == *"$running"* ]]; then
            info "Keeping running kernel package: $pkg"
            continue
        fi
        remove+=("$pkg")
    done
    if (( ${#remove[@]} == 0 )); then
        good "Nothing to remove — already at or under keep policy."
        return 0
    fi
    info "Candidates for removal:"
    printf '       %s\n' "${remove[@]}"
    echo
    if $DRY_RUN; then
        run sudo dnf remove -y "${remove[@]}"
        return 0
    fi
    if confirm "Remove ${#remove[@]} old kernel package(s)?"; then
        safety_gates || return 1
        log_start "kernel-cleanup"
        snapshot_pre_update
        sudo dnf remove -y "${remove[@]}" && good "Old kernels removed." || fail "dnf remove reported errors."
        log_dnf_tx; snapshot_post_update; log_finish
    else
        return 1
    fi
}

# ─────────────────────── Groups & modules ─────────────────────────────
do_groups() {
    title "DNF package groups"
    guard_atomic || return 1
    need_sudo || return 1
    info "Installed groups (upgradeable via 'dnf group upgrade'):"
    local glist=""
    if _ui_progress; then
        spinner_soft glist "Listing installed package groups" bash -c '
            dnf -q group list --installed 2>/dev/null \
            || dnf -q group list installed 2>/dev/null
        '
    else
        glist=$(dnf -q group list --installed 2>/dev/null || dnf -q group list installed 2>/dev/null)
    fi
    printf '%s\n' "$glist" | sed 's/^/       /' | head -40
    echo
    if $DRY_RUN; then
        run dnf group upgrade --assumeno
        return 0
    fi
    if confirm "Upgrade all installed package groups?"; then
        safety_gates || return 1
        log_start "group-upgrade"
        snapshot_pre_update
        sudo dnf group upgrade -y && good "Groups upgraded." || warn "group upgrade finished with warnings."
        log_dnf_tx; snapshot_post_update; log_finish
    else
        return 1
    fi
}

do_modules() {
    title "DNF modules"
    guard_atomic || return 1
    if ! dnf module --help &>/dev/null; then
        warn "dnf module command not available on this system."
        return 0
    fi
    info "Enabled module streams:"
    local mlist=""
    if _ui_progress; then
        spinner_soft mlist "Listing enabled module streams" bash -c '
            dnf -q module list --enabled 2>/dev/null \
            || dnf -q module list enabled 2>/dev/null
        '
    else
        mlist=$(dnf -q module list --enabled 2>/dev/null || dnf -q module list enabled 2>/dev/null)
    fi
    printf '%s\n' "$mlist" | sed 's/^/       /' | head -40
    echo
    info "Module packages update with normal 'dnf upgrade' when streams are enabled."
    if confirm "Refresh module metadata (dnf makecache)?"; then
        need_sudo || return 1
        spinner "Refreshing metadata" sudo dnf -q makecache
    fi
    good "Review streams above; use 'dnf module enable/reset' for stream changes."
}

# ──────────────────── Offline / staged upgrades ───────────────────────
do_offline() {
    title "Offline (staged) system upgrade"
    guard_atomic || return 1
    mapfile -t _ex < <(dnf_exclude_args)
    show_tx_estimate
    if $DRY_RUN; then
        info "Dry-run — would download offline transaction:"
        run dnf upgrade --refresh --offline --assumeno "${_ex[@]}"
        return 0
    fi
    need_sudo || return 1
    safety_gates || return 1
    info "Downloads packages now; applies them on next reboot (safer for kernel/glibc)."
    if confirm "Download full upgrade for offline apply?"; then
        log_start "offline-download"
        snapshot_pre_update
        # dnf5: upgrade --offline; also support offline-upgrade download alias
        if sudo dnf upgrade --refresh --offline -y "${_ex[@]}"; then
            good "Offline transaction downloaded."
        elif sudo dnf offline-upgrade download -y "${_ex[@]}"; then
            good "Offline transaction downloaded (offline-upgrade)."
        else
            fail "Offline download failed."
            log_finish
            return 2
        fi
        log_dnf_tx; log_finish
        echo
        info "Status:"
        dnf offline status 2>/dev/null | sed 's/^/       /' \
            || dnf offline-upgrade status 2>/dev/null | sed 's/^/       /'
        if confirm "Reboot now to apply the offline upgrade?"; then
            run sudo dnf offline reboot || run sudo dnf offline-upgrade reboot
        else
            info "Apply later:  sudo dnf offline reboot"
        fi
    else
        return 1
    fi
}

# ─────────────────────────── Rollback ─────────────────────────────────
do_rollback() {
    title "Rollback (snapper / Btrfs)"
    need_sudo || return 1
    local fstype; fstype=$(findmnt -no FSTYPE / 2>/dev/null)
    if [[ "$fstype" != "btrfs" ]]; then
        warn "Root is $fstype — snapper rollback requires Btrfs."
        return 1
    fi
    if ! command -v snapper &>/dev/null || ! sudo snapper -c root list &>/dev/null; then
        warn "snapper is not configured for root."
        info "Create pre-update snapshots first (menu → Snapshots), or install snapper."
        return 1
    fi
    echo
    sudo snapper -c root list | tail -n 15 | sed 's/^/     /'
    echo
    info "Rollback boots into a snapshot (or rewrites default subvolume — depends on setup)."
    warn "This is disruptive. Prefer: reboot → GRUB → pick a snapper snapshot."
    printf "  ${FG_YELLOW}?${RESET}  Snapshot number to roll back to (empty cancels): "
    local num; read -r num
    [[ -z "$num" ]] && return 1
    [[ "$num" =~ ^[0-9]+$ ]] || { fail "Not a number."; return 1; }
    if $DRY_RUN; then
        run sudo snapper -c root rollback "$num"
        return 0
    fi
    if confirm "Really roll back to snapshot #$num?"; then
        log_start "rollback-$num"
        sudo snapper -c root rollback "$num" && good "Rollback to #$num scheduled/complete." \
            || fail "snapper rollback failed."
        log_finish
        warn "Reboot to finish applying the rollback."
        confirm "Reboot now?" && run sudo systemctl reboot
    else
        return 1
    fi
}

# ──────────────────── Unified pending search ──────────────────────────
do_unified_search() {
    title "Search pending updates (all sources)"
    printf "  ${FG_YELLOW}?${RESET}  filter (substring, empty = show all): "
    local filter; read -r filter
    filter="${filter,,}"
    echo
    info "Querying sources — each step may take a moment…"
    echo
    local hits=0 line name out=""

    # ── dnf ──
    if _ui_progress; then
        spinner_soft out "dnf: checking for updates" dnf -q check-update
    else
        out=$(dnf -q check-update 2>/dev/null) || true
    fi
    info "── dnf ──"
    while read -r name ver repo; do
        [[ -z "$name" || "$name" == Obsoleting* ]] && continue
        pkg_excluded "$name" && continue
        if [[ -z "$filter" || "${name,,}" == *"$filter"* ]]; then
            printf "       ${FG_CYAN}dnf${RESET}  %-42s %s\n" "$name" "$ver"
            (( hits++ )) || true
        fi
    done < <(printf '%s\n' "$out" | awk 'NF==3')

    # ── flatpak ──
    if ! $SKIP_FLATPAK && command -v flatpak &>/dev/null; then
        if _ui_progress; then
            spinner_soft out "flatpak: checking for updates" \
                flatpak remote-ls --updates --columns=application,version
        else
            out=$(flatpak remote-ls --updates --columns=application,version 2>/dev/null)
        fi
        info "── flatpak ──"
        while read -r name ver _; do
            [[ -z "$name" || "$name" == Application ]] && continue
            if [[ -z "$filter" || "${name,,}" == *"$filter"* ]]; then
                printf "       ${FG_MAGENTA}flatpak${RESET}  %-42s %s\n" "$name" "$ver"
                (( hits++ )) || true
            fi
        done < <(printf '%s\n' "$out")
    fi

    # ── snap ──
    if ! $SKIP_SNAP && command -v snap &>/dev/null; then
        if _ui_progress; then
            spinner_soft out "snap: checking for updates" snap refresh --list
        else
            out=$(snap refresh --list 2>/dev/null)
        fi
        info "── snap ──"
        while read -r name ver _; do
            [[ -z "$name" || "$name" == Name ]] && continue
            if [[ -z "$filter" || "${name,,}" == *"$filter"* ]]; then
                printf "       ${FG_ORANGE}snap${RESET}  %-42s %s\n" "$name" "$ver"
                (( hits++ )) || true
            fi
        done < <(printf '%s\n' "$out" | tail -n +2)
    fi

    # ── firmware ──
    if ! $SKIP_FIRMWARE && command -v fwupdmgr &>/dev/null; then
        if _ui_progress; then
            spinner_soft out "firmware: checking LVFS for updates" fwupdmgr get-updates
        else
            out=$(fwupdmgr get-updates 2>/dev/null)
        fi
        info "── firmware ──"
        while read -r line; do
            [[ -z "$line" ]] && continue
            if [[ -z "$filter" || "${line,,}" == *"$filter"* ]]; then
                printf "       ${FG_GREEN}fw${RESET}  %s\n" "$line"
                (( hits++ )) || true
            fi
        done < <(printf '%s\n' "$out" | grep -E 'New version|Update' || true)
    fi

    echo
    if (( hits == 0 )); then
        good "No pending updates matched."
    else
        info "$hits matching line(s)."
    fi
}

# ────────────────────── Diff last history run ─────────────────────────
do_diff_last() {
    title "What changed since last fedup run"
    local -a logs
    mapfile -t logs < <(ls -1t "$HIST_DIR"/*.log 2>/dev/null)
    if (( ${#logs[@]} == 0 )); then
        info "No history reports yet."
        return 0
    fi
    local latest="${logs[0]}"
    info "Latest report: ${FG_GRAY}${latest/#$HOME/\~}${RESET}"
    echo
    # Show high-signal lines from the report
    if grep -q 'dnf transaction' "$latest" 2>/dev/null; then
        info "── dnf transaction excerpt ──"
        sed -n '/dnf transaction/,+40p' "$latest" | head -50 | sed 's/^/     /'
    fi
    echo
    info "── full report summary (non-progress lines) ──"
    grep -Eiv "$PROGRESS_RE" "$latest" 2>/dev/null | grep -E 'Upgraded|Installed|Removed|Complete|kernel|fail|error|updated|✔|failures' | head -40 | sed 's/^/     /' \
        || tail -n 30 "$latest" | sed 's/^/     /'
    echo
    if (( ${#logs[@]} >= 2 )); then
        local prev="${logs[1]}"
        info "Diff vs previous report (${prev##*/}):"
        if command -v diff &>/dev/null; then
            diff -u <(grep -E '^[A-Za-z]|  [A-Za-z]' "$prev" | head -80) \
                    <(grep -E '^[A-Za-z]|  [A-Za-z]' "$latest" | head -80) 2>/dev/null \
                | head -60 | sed 's/^/     /' \
                || info "(no textual diff — reports may be mostly binary-adjacent progress)"
        fi
    fi
    if confirm "Open latest report in less?"; then
        less -R "$latest"
    fi
}

# ────────────────────────── Self-update ───────────────────────────────
do_self_update() {
    title "Self-update fedup"
    local self dest tmp
    self=$(readlink -f "$0")
    info "Current: v$VERSION · $self"
    info "Source:  $SELF_UPDATE_URL"
    if $DRY_RUN; then
        run curl -fsSL "$SELF_UPDATE_URL" -o /tmp/fedup-self-update.sh
        return 0
    fi
    # Prefer git pull when running from a clone
    local dir; dir=$(dirname "$self")
    if [[ -d "$dir/.git" ]] && command -v git &>/dev/null; then
        if confirm "Git repo detected — git pull in $dir?"; then
            if git -C "$dir" pull --ff-only; then
                good "Updated via git. Restart fedup to use the new version."
                return 0
            else
                warn "git pull failed — falling back to URL fetch."
            fi
        fi
    fi
    if ! confirm "Download latest fedup.sh from upstream and replace this file?"; then
        return 1
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/fedup-self.XXXXXX")
    FEDUP_TMPFILES+=("$tmp")
    if _ui_progress; then
        if ! spinner "Downloading latest fedup.sh" curl -fsSL "$SELF_UPDATE_URL" -o "$tmp"; then
            fail "Download failed."
            rm -f "$tmp"
            return 2
        fi
    elif ! curl -fsSL "$SELF_UPDATE_URL" -o "$tmp"; then
        fail "Download failed."
        rm -f "$tmp"
        return 2
    fi
    if ! head -1 "$tmp" | grep -q bash; then
        fail "Downloaded file does not look like a bash script — aborting."
        rm -f "$tmp"
        return 2
    fi
    chmod +x "$tmp"
    if [[ -w "$self" ]]; then
        cp -f "$tmp" "$self"
    else
        need_sudo || return 1
        sudo cp -f "$tmp" "$self"
        sudo chmod +x "$self"
    fi
    rm -f "$tmp"
    good "Replaced $self — restart fedup (new version on next launch)."
}

# ───────────────────── Shell completions ──────────────────────────────
install_completions() {
    title "Install shell completions"
    local bash_dir zsh_dir self
    self=$(readlink -f "$0")
    bash_dir="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}"
    zsh_dir="${ZDOTDIR:-$HOME}/.zfunc"
    mkdir -p "$bash_dir" "$zsh_dir"

    cat > "$bash_dir/fedup" <<'BASH'
# bash completion for fedup
_fedup() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--all --security --check --notify --json --dry-run --remote --remote-check --offline --self-update --install-completion --doctor --version --help -h"
    case "$prev" in
        --remote|--remote-check)
            COMPREPLY=( $(compgen -A hostname -- "$cur") )
            return 0;;
        --dry-run)
            COMPREPLY=( $(compgen -W "--all --security --check --offline --remote" -- "$cur") )
            return 0;;
    esac
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    fi
}
complete -F _fedup fedup fedup.sh
BASH

    cat > "$zsh_dir/_fedup" <<'ZSH'
#compdef fedup fedup.sh
_arguments -s -S \
  '--all[Update everything]' \
  '--security[Security updates only]' \
  '--check[Count pending updates]' \
  '--notify[Desktop notification with --check]' \
  '--json[JSON output]' \
  '--dry-run[Preview without changing]' \
  '--remote[Run --all on remote hosts]:host:_hosts' \
  '--remote-check[Run --check on remote hosts]:host:_hosts' \
  '--offline[Download offline upgrade]' \
  '--self-update[Update fedup itself]' \
  '--install-completion[Install shell completions]' \
  '--doctor[Quick health / pending summary]' \
  '--version[Show version]' \
  '--help[Show help]' \
  '*:host:_hosts'
ZSH

    good "Bash completion → $bash_dir/fedup"
    good "Zsh completion  → $zsh_dir/_fedup"
    info "Bash: restart shell or:  source $bash_dir/fedup"
    info "Zsh: add to ~/.zshrc if needed:"
    printf "       ${FG_GRAY}fpath+=(%s); autoload -Uz compinit && compinit${RESET}\n" "$zsh_dir"
}

# ───────────────────────────── Doctor ─────────────────────────────────
do_doctor() {
    title "fedup doctor — quick status"
    info "fedup v$VERSION · $(source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") · kernel $(uname -r)"
    $IS_ATOMIC && warn "Image-based system (rpm-ostree)" || info "Classic package system (dnf)"
    [[ -n "$EXCLUDE" ]] && info "EXCLUDE=$EXCLUDE"
    echo

    # ── local preflight (instant) ──
    info "── Disk & power ──"
    disk_preflight || true
    if $REQUIRE_AC; then
        on_ac_power && good "On AC power" || warn "On battery (REQUIRE_AC=true)"
    else
        on_ac_power && info "Power: AC (or desktop)" || info "Power: battery"
    fi
    echo

    # ── size estimate (repoquery; has its own spinner via show_tx_estimate) ──
    info "── Download size estimate (dnf) ──"
    info "Querying package metadata — this can take a moment…"
    show_tx_estimate
    echo

    # ── multi-source counts (spinners inside count_updates) ──
    # Don't call do_check: it re-prints a full "Pending updates" title/notify block
    # that feels like a second hung command when nested under doctor.
    info "── Pending updates (all sources) ──"
    info "Checking dnf · flatpak · snap · firmware…"
    echo
    count_updates
    echo
    printf "     dnf packages : %s%d%s   (security: %s%d%s)\n" \
        "$FG_CYAN" "$CNT_DNF" "$RESET" "$FG_RED" "$CNT_SEC" "$RESET"
    printf "     flatpak      : %s%d%s\n" "$FG_CYAN" "$CNT_FLATPAK" "$RESET"
    printf "     snap         : %s%d%s\n" "$FG_CYAN" "$CNT_SNAP" "$RESET"
    printf "     firmware     : %s%d%s\n" "$FG_CYAN" "$CNT_FW" "$RESET"
    $REBOOT && warn "reboot pending from a previous update"
    if (( CNT_TOTAL == 0 )); then
        good "Nothing pending. System looks healthy. 🎉"
    else
        info "Total: ${FG_CYAN}${CNT_TOTAL}${RESET} update(s) across enabled sources"
        info "Use menu → Check for updates / Update everything to act on these."
    fi
}

# ───────────────────────────── History view ───────────────────────────
do_history() {
    title "Update history"
    local logs=("$HIST_DIR"/*.log)
    if [[ ! -e "${logs[0]}" ]]; then
        info "No fedup reports yet — they'll appear here after your first update."
        return
    fi
    local count size
    count=$(ls -1 "$HIST_DIR"/*.log 2>/dev/null | wc -l)
    size=$(du -sh "$HIST_DIR" 2>/dev/null | cut -f1)
    info "$count report(s), $size on disk — newest first:"
    ls -1t "$HIST_DIR" | head -10 | sed 's/^/       /'
    (( count > 10 )) && printf "       ${FG_GRAY}…and %d more${RESET}\n" "$(( count - 10 ))"
    echo
    printf "  ${FG_GRAY}[v] view latest   [o] view older   [d] diff last run   [p] prune to 10   [3] delete >30d   [x] delete all   [Enter] back${RESET}\n"
    local key; IFS= read -rsn1 key
    case "$key" in
        v)  clear; less -R "$(ls -1t "$HIST_DIR"/*.log | head -1)";;
        o)  echo; ls -1t "$HIST_DIR" | nl -w3 -s'. ' | head -20 | sed 's/^/    /'
            printf "\n  report number to view: "; read -r n
            local f; f=$(ls -1t "$HIST_DIR"/*.log | sed -n "${n}p")
            [[ -f "$f" ]] && { clear; less -R "$f"; };;
        d)  do_diff_last;;
        p)  local victims; victims=$(ls -1t "$HIST_DIR"/*.log | tail -n +11)
            if [[ -z "$victims" ]]; then info "Already at 10 or fewer."; else
                confirm "Delete $(wc -l <<< "$victims") old report(s)?" && \
                    { xargs -d '\n' rm -f <<< "$victims"; good "Pruned — 10 newest kept."; }
            fi;;
        3)  local old; old=$(find "$HIST_DIR" -name '*.log' -mtime +30)
            if [[ -z "$old" ]]; then info "Nothing older than 30 days."; else
                confirm "Delete $(wc -l <<< "$old") report(s) older than 30 days?" && \
                    { find "$HIST_DIR" -name '*.log' -mtime +30 -delete; good "Old reports removed."; }
            fi;;
        x)  confirm "Delete ALL $count history reports?" && rm -f "$HIST_DIR"/*.log && good "History cleared.";;
    esac
}

# ───────────────────────────── Config editor ──────────────────────────
write_default_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'EOF'
# fedup configuration — parsed as data, never executed.

# Take snapshots automatically without asking (uses raw btrfs if snapper absent)
ALWAYS_SNAPSHOT=false

# Skip sources during 'update everything' and update counts
SKIP_FLATPAK=false
SKIP_SNAP=false
SKIP_FIRMWARE=false
SKIP_CONTAINERS=false
# User-space updaters (cargo/pipx/npm/brew/AppImage) — off by default
SKIP_USERSPACE=true

# Run 'dnf autoremove' at the end of 'update everything'
AUTOREMOVE=true

# Safety
REQUIRE_AC=false          # true = block big upgrades on battery
MIN_FREE_GB=2             # abort if / or /var has less free space
KERNEL_KEEP=2             # kernels to keep during cleanup (plus running)

# Comma-separated dnf exclude globs (also filters the package picker)
# EXCLUDE=kernel*,akmod*,*.i686

# UI
USE_WHIPTAIL=false        # true = whiptail/dialog for yes/no prompts

# AppImage search paths (colon-separated)
# APPIMAGE_DIRS=/home/you/Applications:/home/you/.local/bin

# Self-update URL
# SELF_UPDATE_URL=https://raw.githubusercontent.com/TonyAldo/fedup/main/fedup.sh
EOF
}

do_config() {
    title "Configuration ($CONFIG_FILE)"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        write_default_config
        good "Created default config."
    fi
    info "Current effective settings:"
    printf "       ALWAYS_SNAPSHOT=%s  AUTOREMOVE=%s  REQUIRE_AC=%s  USE_WHIPTAIL=%s\n" \
           "$ALWAYS_SNAPSHOT" "$AUTOREMOVE" "$REQUIRE_AC" "$USE_WHIPTAIL"
    printf "       SKIP_FLATPAK=%s  SKIP_SNAP=%s  SKIP_FIRMWARE=%s  SKIP_CONTAINERS=%s  SKIP_USERSPACE=%s\n" \
           "$SKIP_FLATPAK" "$SKIP_SNAP" "$SKIP_FIRMWARE" "$SKIP_CONTAINERS" "$SKIP_USERSPACE"
    printf "       KERNEL_KEEP=%s  MIN_FREE_GB=%s\n" "$KERNEL_KEEP" "$MIN_FREE_GB"
    printf "       EXCLUDE=%s\n" "${EXCLUDE:-${FG_GRAY}(none)${RESET}}"
    echo
    if confirm "Open in editor (${EDITOR:-nano})?"; then
        "${EDITOR:-nano}" "$CONFIG_FILE"
        load_config
        good "Config reloaded."
    fi
}

# ──────────────────────────────── Menu ────────────────────────────────
# Entries: "H|label" = section header (not selectable), "fn|label" = action
MENU=(
    "H|── Update ─────────────────────────────────────"
    "do_everything|🚀  Update everything"
    "do_dnf_selective|🎯  Pick which dnf updates to install"
    "do_dnf_full|📦  Full dnf system upgrade"
    "do_security|🛡️  Security updates only (CVE advisories)"
    "do_offline|💾  Offline / staged upgrade (apply at reboot)"
    "do_unified_search|🔍  Search pending updates (all sources)"
    "H|── Sources ────────────────────────────────────"
    "do_flatpak|📱  Flatpak / Flathub (pick & choose)"
    "do_snap|🧩  Snap"
    "do_userspace|🧰  User-space (cargo · pipx · npm · brew · AppImage)"
    "do_codecs|🎬  Third-party codecs (RPM Fusion)"
    "do_firmware|🔌  Device firmware (fwupd / LVFS)"
    "do_containers|📦  Distrobox / Toolbox containers"
    "do_groups|📚  DNF package groups"
    "do_modules|🧩  DNF modules"
    "H|── Maintain ───────────────────────────────────"
    "do_mirrors|🌐  Mirror & download speed tuning"
    "do_snapshots_menu|📸  Btrfs snapshots (snapper)"
    "do_rollback|⏪  Rollback to a snapper snapshot"
    "do_kernel_cleanup|🧹  Kernel cleanup (keep N newest)"
    "do_versionlock|⚲   Package holds (versionlock)"
    "do_restarting|♻️  Restart services holding stale libs"
    "do_copr_health|🩺  COPR repo health check"
    "H|── Automate ───────────────────────────────────"
    "check_menu|🔔  Check for updates now (with counts)"
    "do_doctor|🩺  Doctor — free space, power, pending"
    "do_timers|⏰  Install scheduled check / auto-update timers"
    "do_history|📜  View / prune update history reports"
    "do_diff_last|📋  Diff / summary of last fedup run"
    "do_self_update|⬆️  Self-update fedup"
    "install_completions|⌨️  Install bash/zsh completions"
    "do_config|⚙️  Edit fedup configuration"
    "H|"
    "quit|🚪  Quit"
)

check_menu() { do_check notify; }
quit() { exit 0; }

is_header() { [[ "${MENU[$1]%%|*}" == "H" ]]; }

next_sel() {  # next_sel current direction(+1/-1)
    local i=$1 d=$2 n=${#MENU[@]}
    while true; do
        i=$(( (i + d + n) % n ))
        is_header "$i" || { echo "$i"; return; }
    done
}

# Optional whiptail main menu when USE_WHIPTAIL=true
main_menu_whiptail() {
    local bin entries=() i label tag
    bin=$(_dialog_bin) || return 1
    for i in "${!MENU[@]}"; do
        is_header "$i" && continue
        tag="${MENU[$i]%%|*}"
        label="${MENU[$i]#*|}"
        entries+=("$tag" "$label")
    done
    while true; do
        tag=$("$bin" --title "fedup v$VERSION" --menu "Choose an action" 0 70 16 "${entries[@]}" 3>&1 1>&2 2>&3) || exit 0
        clear; banner
        local arc=0
        "$tag" || arc=$?
        (( arc == 1 )) || pause
    done
}

main_menu() {
    if $USE_WHIPTAIL && _dialog_bin &>/dev/null; then
        main_menu_whiptail
        return
    fi
    local cur; cur=$(next_sel -1 +1)
    local key
    mouse_on
    while true; do
        banner
        # After banner: help line, blank line, then menu entries.
        # First menu row is BANNER_ROWS + 3 (1-based SGR mouse Y).
        local menu_top=$(( BANNER_ROWS + 3 ))
        printf "  ${FG_GRAY}↑/↓ or click · Enter select · q quit${RESET}\n\n"
        # Map every painted menu row → MENU index (-1 = section header, not clickable)
        local -a row_map=()
        for i in "${!MENU[@]}"; do
            local label="${MENU[$i]#*|}"
            if is_header "$i"; then
                printf "  ${FG_GRAY}%s${RESET}\n" "$label"
                row_map+=(-1)
            elif (( i == cur )); then
                printf "  ${BG_SEL}${FG_WHITE} ${ARROW} %-54s ${RESET}\n" "$label"
                row_map+=("$i")
            else
                printf "     %s\n" "$label"
                row_map+=("$i")
            fi
        done
        tput civis 2>/dev/null
        IFS= read -rsn1 key
        if [[ "$key" == "$ESC" ]]; then
            read_esc_sequence
            local esc_rc=$?
            if (( esc_rc == 0 )); then
                # Map click Y onto the painted row list (includes headers)
                local offset=$(( MOUSE_Y - menu_top ))
                if (( offset >= 0 && offset < ${#row_map[@]} )); then
                    local hit=${row_map[offset]}
                    if (( hit >= 0 )); then
                        cur=$hit
                        clear; banner; mouse_off
                        local arc=0
                        "${MENU[$cur]%%|*}" || arc=$?
                        (( arc == 1 )) || pause
                        mouse_on
                    fi
                fi
                continue
            elif (( esc_rc == 2 )); then
                key="$CSI_KEY"
            else
                continue
            fi
        fi
        tput cnorm 2>/dev/null
        case "$key" in
            "${ESC}[A") cur=$(next_sel "$cur" -1);;
            "${ESC}[B") cur=$(next_sel "$cur" +1);;
            q) mouse_off; exit 0;;
            "")
                clear; banner; mouse_off
                local arc=0
                "${MENU[$cur]%%|*}" || arc=$?
                # return 1 = cancelled / declined / aborted early → skip extra Enter
                (( arc == 1 )) || pause
                mouse_on
                ;;
        esac
    done
}

# ──────────────────────────────── Entry ───────────────────────────────
JSON_OUT=false
NOTIFY=false
ARGS=()
for a in "$@"; do
    case "$a" in
        --json)    JSON_OUT=true;;
        --notify)  NOTIFY=true;;
        --dry-run) DRY_RUN=true;;
        --whiptail) USE_WHIPTAIL=true;;
        *)        ARGS+=("$a");;
    esac
done
set -- "${ARGS[@]}"

case "$1" in
    --all)
        banner
        do_everything
        exit $?;;
    --security)
        banner
        do_security
        exit $?;;
    --check)
        $JSON_OUT || banner
        if $NOTIFY; then do_check notify; else do_check; fi
        exit $?;;
    --remote)
        shift; do_remote all "$@"; exit $?;;
    --remote-check)
        shift; do_remote check "$@"; exit $?;;
    --offline)
        banner; do_offline; exit $?;;
    --self-update)
        banner; do_self_update; exit $?;;
    --install-completion|--install-completions)
        banner; install_completions; exit $?;;
    --doctor)
        banner; do_doctor; exit $?;;
    --version)
        echo "fedup v$VERSION";;
    --help|-h)
        sed -n '3,30p' "$0" | sed 's/^#//';;
    "")
        main_menu;;
    *)
        fail "unknown option: $1  (try --help)"; exit 2;;
esac
