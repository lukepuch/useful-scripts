#!/usr/bin/env bash
# 4-bind-tpm.sh — step 4 of setting up TPM2 auto-unlock: add a TPM-sealed key
# to the LUKS volume, bound to PCR 7 (Secure Boot state).
#
# Usage:
#   4-bind-tpm.sh    (needs sudo; clevis then prompts for your LUKS passphrase)
#
# clevis adds its own key slot and token. The existing passphrase slot is not
# touched and stays as the fallback.
#
# Refuses to run if Secure Boot is off (PCR 7 would protect almost nothing,
# and enabling it later changes PCR 7 and invalidates the binding), if the
# step 1 header backup is missing, or if the volume is already bound.

set -euo pipefail

LUKS_DEV=/dev/disk/by-uuid/d4129ba6-8abf-46f6-a410-b6ec9cbf364f
PIN_CONFIG='{"pcr_bank":"sha256","pcr_ids":"7"}'

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

dev=$(readlink -f "$LUKS_DEV")

if [[ $(mokutil --sb-state 2>/dev/null) != *enabled* ]]; then
    echo "Secure Boot is not enabled — enable it in firmware first (step 2)." >&2
    exit 1
fi

if ! compgen -G '/root/luks-header-*.img' >/dev/null; then
    echo "No LUKS header backup in /root — run 1-backup-luks-header-and-initrd.sh first." >&2
    exit 1
fi

existing=$(clevis luks list -d "$dev")
if [[ -n $existing ]]; then
    echo "$dev already has a clevis binding:" >&2
    echo "  $existing" >&2
    echo "Use reseal.sh to replace it, or rollback.sh to remove it." >&2
    exit 1
fi

echo "Binding $dev to the TPM with $PIN_CONFIG"
echo "clevis will now ask for your existing LUKS passphrase."
clevis luks bind -d "$dev" tpm2 "$PIN_CONFIG"

echo
echo "Bindings on $dev:"
clevis luks list -d "$dev" | sed 's/^/  /'
echo
echo "Done. Next: 5-rebuild-initramfs.sh"
