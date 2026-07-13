#!/usr/bin/env bash
#
#      ▐▛███▜▌      f e d u p  v2
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
#
#  FILES
#    ~/.config/fedup/config          user config (always-snapshot, skip sources…)
#    ~/.local/share/fedup/history/   per-run transaction reports
#    ~/.config/systemd/user/         fedup-check.timer (if installed)
#
set -o pipefail

VERSION="2.2"
HIST_DIR="$HOME/.local/share/fedup/history"
mkdir -p "$HIST_DIR" 2>/dev/null
# Temp files created during a run (spinner logs, etc.) — cleaned on EXIT
FEDUP_TMPFILES=()

# ─────────────────────────── Config file ──────────────────────────────
CONFIG_FILE="$HOME/.config/fedup/config"
# Defaults (overridable in $CONFIG_FILE)
ALWAYS_SNAPSHOT=false     # take snapshots without asking (raw btrfs fallback too)
SKIP_FLATPAK=false        # skip flatpak in 'update everything' & counts
SKIP_SNAP=false           # skip snap in 'update everything' & counts
SKIP_FIRMWARE=false       # skip fwupd in 'update everything' & counts
SKIP_CONTAINERS=false     # skip distrobox/toolbox in 'update everything'
AUTOREMOVE=true           # run dnf autoremove at end of 'update everything'

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local key val
    # Whitelisted keys only — the config is data, never executed.
    while IFS='=' read -r key val; do
        key="${key//[[:space:]]/}"; val="${val//[[:space:]]/}"; val="${val%%#*}"
        case "$key" in
            ALWAYS_SNAPSHOT|SKIP_FLATPAK|SKIP_SNAP|SKIP_FIRMWARE|SKIP_CONTAINERS|AUTOREMOVE)
                [[ "$val" =~ ^(true|false)$ ]] && printf -v "$key" '%s' "$val";;
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

banner() {
    clear
    printf "${FG_MAGENTA}"
    cat <<'EOF'
      ▐▛███▜▌
     ▟██████▙     f e d u p  v2
    ▐████████▌    ─────────────────────────────
     ▜██████▛     Fedora Update Utility
      ▘▘ ▝▝
EOF
    printf "${RESET}"
    printf "  ${FG_GRAY}%s · kernel %s · %s${RESET}\n" \
        "$(source /etc/os-release && echo "$PRETTY_NAME")" \
        "$(uname -r)" \
        "$(date '+%a %b %d, %I:%M %p')"
    $DRY_RUN   && printf "  ${FG_YELLOW}▷ DRY-RUN MODE — nothing will be changed${RESET}\n"
    $IS_ATOMIC && printf "  ${FG_ORANGE}⬢ image-based system (rpm-ostree) — dnf features are guarded${RESET}\n"
    echo
}

spinner() {  # spinner "message" -- command...
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
    rm -f "$spinlog"
    return $rc
}

confirm() {
    local ans
    printf "  ${FG_YELLOW}?${RESET}  %s ${FG_GRAY}[y/N]${RESET} " "$1"
    read -r ans
    [[ "$ans" =~ ^[Yy] ]]
}

pause() { printf "\n  ${FG_GRAY}press Enter to return to menu…${RESET}"; read -r; }

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
    need_sudo || return
    local fstype; fstype=$(findmnt -no FSTYPE /)
    info "Root filesystem: $fstype"
    if command -v snapper &>/dev/null && sudo snapper -c root list &>/dev/null; then
        echo
        sudo snapper -c root list | tail -n 12 | sed 's/^/     /'
        echo
        confirm "Create a manual snapshot now?" && \
            sudo snapper -c root create --description "fedup manual $(date +%F_%H%M)" && \
            good "Snapshot created."
        info "Rollback: boot a snapshot from GRUB or run  sudo snapper rollback <N>"
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
    local seclist
    seclist=$(dnf -q updateinfo list --updates --security 2>/dev/null | tail -n +2)
    [[ -z "$seclist" ]] && seclist=$(dnf -q advisory list --security --available 2>/dev/null | tail -n +2)
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
    if $DRY_RUN; then
        info "Dry-run — transaction preview only (no sudo required):"
        dnf upgrade --security --assumeno
        return 0
    fi
    if confirm "Apply security updates only ($n advisories)?"; then
        log_start "security-updates"
        snapshot_pre_update
        sudo dnf upgrade --security -y && good "Security updates applied." || fail "dnf reported errors."
        log_dnf_tx; snapshot_post_update; log_finish
        return 0
    fi
    return 1  # user declined
}

# ────────────── DNF updates + interactive picker (v2) ─────────────────
declare -a PKG_NAME PKG_VER PKG_REPO PKG_SEL

fetch_updates() {
    PKG_NAME=(); PKG_VER=(); PKG_REPO=(); PKG_SEL=()
    # Dry-run / unprivileged path can refresh without sudo when metadata is readable.
    if $DRY_RUN || (( EUID == 0 )); then
        spinner "Refreshing metadata & checking for updates" dnf -q --refresh check-update
    else
        spinner "Refreshing metadata & checking for updates" sudo dnf -q --refresh check-update
    fi
    local rc=$?
    if (( rc == 0 )); then return 1; fi
    if (( rc != 100 )); then fail "dnf check-update failed (rc=$rc)"; return 2; fi
    while read -r name ver repo; do
        [[ -z "$name" || "$name" == Obsoleting* ]] && continue
        PKG_NAME+=("$name"); PKG_VER+=("$ver"); PKG_REPO+=("$repo"); PKG_SEL+=(1)
    done < <(dnf -q check-update 2>/dev/null | awk 'NF==3')
    (( ${#PKG_NAME[@]} > 0 ))
}

show_changelog() {  # show_changelog pkgname
    clear
    printf "\n  ${BOLD}${FG_CYAN}Changelog / advisory — %s${RESET}\n" "$1"
    hr
    {
        # dnf5 prefers --count=N; dnf4 accepts --count N. Fall through advisory/info.
        dnf -q changelog --count=3 "$1" 2>/dev/null \
        || dnf -q changelog --count 3 "$1" 2>/dev/null \
        || dnf -q updateinfo info "$1" 2>/dev/null \
        || dnf -q advisory info "$1" 2>/dev/null \
        || dnf -q repoquery --info "$1" 2>/dev/null \
        || dnf -q info "$1" 2>/dev/null
    } | head -40 | sed 's/^/   /'
    hr
    printf "  ${FG_GRAY}press any key to return…${RESET}"
    IFS= read -rsn1
}

pick_packages() {
    local page=0 per=14 cur=0 key filter="" total
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
    while true; do
        clear
        printf "\n  ${BOLD}${FG_CYAN}Select updates${RESET}  ${FG_GRAY}(%d shown / %d total)${RESET}" "$total" "${#PKG_NAME[@]}"
        [[ -n "$filter" ]] && printf "  ${FG_YELLOW}filter: %s${RESET}" "$filter"
        printf "\n  ${FG_GRAY}↑/↓ move · space toggle · a all · n none · / filter · c changelog · p pin/hold · Enter apply · q cancel${RESET}\n"
        hr
        if (( total == 0 )); then
            printf "\n     ${FG_GRAY}no packages match '%s' — press / to change the filter${RESET}\n\n" "$filter"
        fi
        local start=$(( page * per )); local end=$(( start + per - 1 ))
        (( end >= total )) && end=$(( total - 1 ))
        for v in $(seq "$start" "$end"); do
            (( total == 0 )) && break
            local i=${VIEW[v]}
            # Consistent ●/○ glyph; selection row uses reverse-video so drop per-glyph color.
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
        done
        local selcount=0; for s in "${PKG_SEL[@]}"; do (( selcount += s )); done
        hr
        printf "  ${FG_GREEN}%d selected${RESET} ${FG_GRAY}· page %d/%d${RESET}\n" \
               "$selcount" "$(( page + 1 ))" "$(( total > 0 ? (total + per - 1) / per : 1 ))"

        IFS= read -rsn1 key
        [[ "$key" == "$ESC" ]] && { read -rsn2 -t 0.01 key2; key="${ESC}${key2}"; }
        local ci=-1; (( total > 0 )) && ci=${VIEW[cur]}   # real index under cursor
        case "$key" in
            "${ESC}[A") (( cur > 0 )) && (( cur-- )); (( cur < page*per )) && (( page-- ));;
            "${ESC}[B") (( cur < total-1 )) && (( cur++ )); (( cur >= (page+1)*per )) && (( page++ ));;
            " ")      (( ci >= 0 )) && PKG_SEL[ci]=$(( 1 - PKG_SEL[ci] ));;
            a)        for v in "${VIEW[@]}"; do PKG_SEL[v]=1; done;;
            n)        for v in "${VIEW[@]}"; do PKG_SEL[v]=0; done;;
            /)        tput cnorm
                      printf "\r\033[K  filter (empty to clear): "
                      read -r filter
                      cur=0; page=0; build_view
                      tput civis 2>/dev/null;;
            c)        (( ci >= 0 )) && { show_changelog "${PKG_NAME[ci]}"; tput civis 2>/dev/null; };;
            p)        if (( ci >= 0 )); then
                          tput cnorm
                          if ensure_versionlock; then
                              sudo dnf versionlock add "${PKG_NAME[ci]}" &>/dev/null \
                                  && PKG_SEL[ci]=0 \
                                  && PKG_REPO[ci]="⚲ held"
                          fi
                          tput civis 2>/dev/null
                      fi;;
            q)        tput cnorm; return 1;;
            "")       tput cnorm; return 0;;
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
    if $DRY_RUN; then
        info "Dry-run — transaction preview only (no sudo required):"
        dnf upgrade --assumeno "${chosen[@]}"
        return 0
    fi
    log_start "selective-dnf"
    snapshot_pre_update
    sudo dnf upgrade -y "${chosen[@]}" && good "Selected packages updated." || fail "dnf upgrade reported errors."
    log_dnf_tx; snapshot_post_update; log_finish
}

do_dnf_full() {
    title "Full system upgrade (dnf)"
    guard_atomic || return 1
    if $DRY_RUN; then
        info "Dry-run — transaction preview only (no sudo required):"
        dnf upgrade --refresh --assumeno
        return 0
    fi
    need_sudo || return 1
    log_start "full-dnf"
    snapshot_pre_update
    sudo dnf upgrade --refresh -y && good "System packages updated." || fail "dnf upgrade reported errors."
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
do_flatpak() {
    title "Flatpak / Flathub"
    if ! command -v flatpak &>/dev/null; then
        warn "flatpak is not installed."
        confirm "Install flatpak now?" && { need_sudo && sudo dnf install -y flatpak; } || return
    fi
    if ! flatpak remotes | grep -qi flathub; then
        confirm "Flathub remote missing — add it?" && \
            flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    fi
    local pending
    pending=$(flatpak remote-ls --updates 2>/dev/null | wc -l)
    if (( pending == 0 )); then
        good "All Flatpaks are current."
    else
        info "$pending Flatpak update(s) available:"
        flatpak remote-ls --updates --columns=application,version 2>/dev/null | sed 's/^/       /'
        echo
        if confirm "Update all Flatpaks?"; then
            log_start "flatpak"
            run log_cmd flatpak update -y && good "Flatpaks updated."
            log_finish
        fi
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
    local list; list=$(snap refresh --list 2>/dev/null | tail -n +2)
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
    local updates
    updates=$(fwupdmgr get-updates 2>/dev/null)
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
    if reboot_needed; then
        warn "Kernel or core libraries changed — a full reboot IS recommended."
    else
        dnf needs-restarting -r &>/dev/null
        local nrc=$?
        if (( nrc == 0 )); then
            good "Core system is clean — no reboot required."
        else
            warn "needs-restarting unavailable (install dnf5-plugins / dnf-plugins-core) — cannot assess reboot."
        fi
    fi
    echo
    local svcs
    svcs=$(dnf_stale_services)
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
    for f in $repos; do
        local name enabled url
        name=$(grep -m1 '^\[' "$f" | tr -d '[]')
        enabled=$(grep -m1 '^enabled' "$f" | grep -o '[01]')
        url=$(grep -m1 '^baseurl' "$f" | cut -d= -f2- | sed "s/\$releasever/$rel/g; s/\$basearch/$arch/g" | tr -d ' ')
        if [[ "$enabled" != "1" ]]; then
            printf "  ${FG_GRAY}−  %s (disabled)${RESET}\n" "$name"
            continue
        fi
        if [[ -n "$url" ]] && curl -sfIL --max-time 8 "${url%/}/repodata/repomd.xml" &>/dev/null; then
            printf "  ${OK}  %s\n" "$name"
        else
            printf "  ${ERR}  %s  ${FG_RED}← unreachable for Fedora %s (dead/abandoned COPR?)${RESET}\n" "$name" "$rel"
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
count_updates() {  # sets CNT_DNF CNT_SEC CNT_FLATPAK CNT_SNAP CNT_FW REBOOT
    # Honors SKIP_* config so --check / notifications match 'update everything'.
    CNT_DNF=0; CNT_SEC=0; CNT_FLATPAK=0; CNT_SNAP=0; CNT_FW=0; REBOOT=false
    dnf -q check-update --refresh &>/dev/null
    (( $? == 100 )) && CNT_DNF=$(dnf -q check-update 2>/dev/null | awk 'NF==3' | grep -vc '^Obsoleting' )
    local sec_out
    sec_out=$(dnf -q updateinfo list --updates --security 2>/dev/null | tail -n +2)
    # dnf5: updateinfo is an alias for advisory; keep both for older/plugin edge cases
    [[ -z "$sec_out" ]] && sec_out=$(dnf -q advisory list --security --available 2>/dev/null | tail -n +2)
    CNT_SEC=$(printf '%s\n' "$sec_out" | grep -c . || true)
    if ! $SKIP_FLATPAK && command -v flatpak &>/dev/null; then
        CNT_FLATPAK=$(flatpak remote-ls --updates 2>/dev/null | wc -l)
    fi
    if ! $SKIP_SNAP && command -v snap &>/dev/null; then
        CNT_SNAP=$(snap refresh --list 2>/dev/null | tail -n +2 | wc -l)
    fi
    if ! $SKIP_FIRMWARE && command -v fwupdmgr &>/dev/null; then
        fwupdmgr get-updates &>/dev/null && CNT_FW=$(fwupdmgr get-updates 2>/dev/null | grep -c 'New version' )
    fi
    reboot_needed && REBOOT=true
    CNT_TOTAL=$(( CNT_DNF + CNT_FLATPAK + CNT_SNAP + CNT_FW ))
}

do_check() {  # $1 = "notify" to send desktop notification, JSON handled by caller
    count_updates
    if $JSON_OUT; then
        printf '{"host":"%s","dnf":%d,"security":%d,"flatpak":%d,"snap":%d,"firmware":%d,"total":%d,"reboot_needed":%s}\n' \
            "$(hostname)" "$CNT_DNF" "$CNT_SEC" "$CNT_FLATPAK" "$CNT_SNAP" "$CNT_FW" "$CNT_TOTAL" "$REBOOT"
    else
        title "Pending updates on $(hostname)"
        printf "     dnf packages : %s%d%s   (security: %s%d%s)\n" "$FG_CYAN" "$CNT_DNF" "$RESET" "$FG_RED" "$CNT_SEC" "$RESET"
        printf "     flatpak      : %s%d%s\n" "$FG_CYAN" "$CNT_FLATPAK" "$RESET"
        printf "     snap         : %s%d%s\n" "$FG_CYAN" "$CNT_SNAP" "$RESET"
        printf "     firmware     : %s%d%s\n" "$FG_CYAN" "$CNT_FW" "$RESET"
        $REBOOT && warn "reboot pending from a previous update"
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
    if ! $DRY_RUN; then
        need_sudo || return 1
    fi
    if $DRY_RUN; then
        info "Dry-run — this is what an 'update everything' run would do:"
        count_updates
        printf "     dnf: %d pkgs (%d security) · flatpak: %d · snap: %d · firmware: %d\n" \
               "$CNT_DNF" "$CNT_SEC" "$CNT_FLATPAK" "$CNT_SNAP" "$CNT_FW"
        if $IS_ATOMIC; then
            run sudo rpm-ostree upgrade
        else
            run dnf upgrade --refresh --assumeno
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
        ! $IS_ATOMIC && $AUTOREMOVE && run dnf autoremove --assumeno
        return 0
    fi
    log_start "everything"
    snapshot_pre_update
    local failures=0
    if $IS_ATOMIC; then
        spinner "rpm-ostree: upgrading base image" sudo rpm-ostree upgrade || (( failures++ )) || true
    else
        spinner "dnf: full system upgrade" sudo dnf upgrade --refresh -y || (( failures++ )) || true
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
    printf "  ${FG_GRAY}[v] view latest   [o] view older (pick)   [p] prune to 10 newest   [3] delete >30 days old   [x] delete all   [Enter] back${RESET}\n"
    local key; IFS= read -rsn1 key
    case "$key" in
        v)  clear; less -R "$(ls -1t "$HIST_DIR"/*.log | head -1)";;
        o)  echo; ls -1t "$HIST_DIR" | nl -w3 -s'. ' | head -20 | sed 's/^/    /'
            printf "\n  report number to view: "; read -r n
            local f; f=$(ls -1t "$HIST_DIR"/*.log | sed -n "${n}p")
            [[ -f "$f" ]] && { clear; less -R "$f"; };;
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
do_config() {
    title "Configuration ($CONFIG_FILE)"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        cat > "$CONFIG_FILE" <<'EOF'
# fedup configuration — true/false values only, one per line.
# Lines are parsed as data, never executed.

# Take snapshots automatically without asking (uses raw btrfs if snapper absent)
ALWAYS_SNAPSHOT=false

# Skip sources during 'update everything' and update counts
SKIP_FLATPAK=false
SKIP_SNAP=false
SKIP_FIRMWARE=false
SKIP_CONTAINERS=false

# Run 'dnf autoremove' at the end of 'update everything'
AUTOREMOVE=true
EOF
        good "Created default config."
    fi
    info "Current effective settings:"
    printf "       ALWAYS_SNAPSHOT=%s  AUTOREMOVE=%s\n" "$ALWAYS_SNAPSHOT" "$AUTOREMOVE"
    printf "       SKIP_FLATPAK=%s  SKIP_SNAP=%s  SKIP_FIRMWARE=%s  SKIP_CONTAINERS=%s\n" \
           "$SKIP_FLATPAK" "$SKIP_SNAP" "$SKIP_FIRMWARE" "$SKIP_CONTAINERS"
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
    "do_everything|🚀  Update everything (dnf · flatpak · snap · firmware)"
    "do_dnf_selective|🎯  Pick which dnf updates to install"
    "do_dnf_full|📦  Full dnf system upgrade"
    "do_security|🛡️   Security updates only (CVE advisories)"
    "H|── Sources ────────────────────────────────────"
    "do_flatpak|📱  Flatpak / Flathub"
    "do_snap|🧩  Snap"
    "do_codecs|🎬  Third-party codecs (RPM Fusion)"
    "do_firmware|🔌  Device firmware (fwupd / LVFS)"
    "do_containers|📦  Distrobox / Toolbox containers"
    "H|── Maintain ───────────────────────────────────"
    "do_mirrors|🌐  Mirror & download speed tuning"
    "do_snapshots_menu|📸  Btrfs snapshots (snapper)"
    "do_versionlock|⚲   Package holds (versionlock)"
    "do_restarting|♻️   Restart services holding stale libs"
    "do_copr_health|🩺  COPR repo health check"
    "H|── Automate ───────────────────────────────────"
    "check_menu|🔔  Check for updates now (with counts)"
    "do_timers|⏰  Install scheduled check / auto-update timers"
    "do_history|📜  View / prune update history reports"
    "do_config|⚙️   Edit fedup configuration"
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

main_menu() {
    local cur; cur=$(next_sel -1 +1)
    local key
    while true; do
        banner
        printf "  ${FG_GRAY}↑/↓ to move · Enter to select · q quit${RESET}\n\n"
        for i in "${!MENU[@]}"; do
            local label="${MENU[$i]#*|}"
            if is_header "$i"; then
                printf "  ${FG_GRAY}%s${RESET}\n" "$label"
            elif (( i == cur )); then
                printf "  ${BG_SEL}${FG_WHITE} ${ARROW} %-54s ${RESET}\n" "$label"
            else
                printf "     %s\n" "$label"
            fi
        done
        tput civis 2>/dev/null
        IFS= read -rsn1 key
        [[ "$key" == "$ESC" ]] && { read -rsn2 -t 0.01 key2; key="${ESC}${key2}"; }
        tput cnorm 2>/dev/null
        case "$key" in
            "${ESC}[A") cur=$(next_sel "$cur" -1);;
            "${ESC}[B") cur=$(next_sel "$cur" +1);;
            q) exit 0;;
            "")
                clear; banner
                local arc=0
                "${MENU[$cur]%%|*}" || arc=$?
                # return 1 = cancelled / declined / aborted early → skip extra Enter
                (( arc == 1 )) || pause
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
    --version)
        echo "fedup v$VERSION";;
    --help|-h)
        sed -n '3,25p' "$0" | sed 's/^#//';;
    "")
        main_menu;;
    *)
        fail "unknown option: $1  (try --help)"; exit 2;;
esac
