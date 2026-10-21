#!/usr/bin/env bash
# sleep-settings.sh — show or change whether this machine can sleep/suspend.
#
# Usage:
#   sleep-settings.sh status    Show current sleep-related settings (no root needed)
#   sleep-settings.sh disable   Keep the machine awake 24/7 (needs sudo)
#   sleep-settings.sh enable    Undo "disable" and restore distro defaults (needs sudo)
#   Add --restart-logind to disable/enable to apply logind changes immediately.
#
# "disable" does two things:
#   1. Masks the systemd sleep targets, so nothing (lid, idle timer, power
#      button, a stray `systemctl suspend`) can put the machine to sleep.
#      Takes effect immediately.
#   2. Installs a logind drop-in telling logind to ignore lid/idle/suspend
#      triggers. Takes effect on next reboot, or right away with --restart-logind.
#
# Restarting systemd-logind can end graphical desktop sessions; SSH sessions
# are normally unaffected. That's why it's opt-in.

set -euo pipefail

SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
LOGIND_DROPIN=/etc/systemd/logind.conf.d/99-no-sleep.conf
LOGIND_KEYS=(HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked HandleSuspendKey HandleHibernateKey IdleAction IdleActionUSec)

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo "$0" "$@"
    fi
}

logind_prop() {
    busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager "$1" 2>/dev/null | cut -d' ' -f2- | tr -d '"' || echo "?"
}

status() {
    echo "== systemd sleep targets =="
    for t in "${SLEEP_TARGETS[@]}"; do
        printf '  %-32s %s\n' "$t" "$(systemctl is-enabled "$t" 2>/dev/null || true)"
    done
    echo "  (\"masked\" means sleep is blocked; \"static\" means sleep is allowed)"

    echo
    echo "== logind (live values) =="
    for k in "${LOGIND_KEYS[@]}"; do
        local v
        v=$(logind_prop "$k")
        printf '  %-32s %s\n' "$k" "${v:-(unset — follows HandleLidSwitch)}"
    done

    echo
    echo "== logind drop-in =="
    if [[ -f $LOGIND_DROPIN ]]; then
        echo "  $LOGIND_DROPIN present:"
        sed 's/^/    /' "$LOGIND_DROPIN"
    else
        echo "  $LOGIND_DROPIN not present"
    fi

    echo
    echo "== summary =="
    if [[ $(systemctl is-enabled suspend.target 2>/dev/null || true) == masked ]]; then
        echo "  Sleep is DISABLED — the machine will stay awake."
    else
        echo "  Sleep is ALLOWED — the machine may suspend (e.g. lid close: $(logind_prop HandleLidSwitch))."
    fi
}

disable_sleep() {
    local restart=$1
    echo "Masking sleep targets..."
    systemctl mask "${SLEEP_TARGETS[@]}"

    echo "Writing $LOGIND_DROPIN..."
    mkdir -p "$(dirname "$LOGIND_DROPIN")"
    cat > "$LOGIND_DROPIN" <<'EOF'
# Installed by sleep-settings.sh — keep this machine awake 24/7.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF

    if [[ $restart == 1 ]]; then
        echo "Restarting systemd-logind..."
        systemctl restart systemd-logind
    else
        echo "logind settings apply on next reboot (sleep is already blocked by the masked targets)."
    fi
    echo "Done."
}

enable_sleep() {
    local restart=$1
    echo "Unmasking sleep targets..."
    systemctl unmask "${SLEEP_TARGETS[@]}"

    if [[ -f $LOGIND_DROPIN ]]; then
        echo "Removing $LOGIND_DROPIN..."
        rm -f "$LOGIND_DROPIN"
    fi

    if [[ $restart == 1 ]]; then
        echo "Restarting systemd-logind..."
        systemctl restart systemd-logind
    else
        echo "logind defaults return on next reboot (or rerun with --restart-logind)."
    fi
    echo "Done."
}

main() {
    local cmd=${1:-status}
    local restart=0
    [[ ${2:-} == --restart-logind ]] && restart=1

    case $cmd in
        status)        status ;;
        disable)       need_root "$@"; disable_sleep "$restart" ;;
        enable)        need_root "$@"; enable_sleep "$restart" ;;
        -h|--help|help) usage 0 ;;
        *)             usage 1 ;;
    esac
}

main "$@"
