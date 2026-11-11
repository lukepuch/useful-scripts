#!/usr/bin/env bash
# reseal.sh — re-seal the TPM key after PCR 7 has changed (a revocation list
# update, a signing key rotation, a BIOS reset, Secure Boot toggled) and the
# machine stopped at the passphrase prompt on boot.
#
# Usage:
#   reseal.sh    (needs sudo; clevis prompts for your LUKS passphrase)
#
# Adds a new TPM binding against the current PCR 7 value first, and only
# then removes the old one, so the passphrase slot is never the thing being
# changed. The TPM slot number may differ afterwards; that is fine.

set -euo pipefail

LUKS_DEV=/dev/disk/by-uuid/d4129ba6-8abf-46f6-a410-b6ec9cbf364f
PIN_CONFIG='{"pcr_bank":"sha256","pcr_ids":"7"}'

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

dev=$(readlink -f "$LUKS_DEV")

if [[ $(mokutil --sb-state 2>/dev/null) != *enabled* ]]; then
    echo "Secure Boot is not enabled — turn it back on before re-sealing." >&2
    exit 1
fi

old_slots=$(clevis luks list -d "$dev" | sed -n 's/^\([0-9]\+\): tpm2 .*/\1/p')

echo "Adding a new TPM binding on $dev with $PIN_CONFIG"
echo "clevis will now ask for your existing LUKS passphrase."
clevis luks bind -d "$dev" tpm2 "$PIN_CONFIG"

for slot in $old_slots; do
    echo "Removing old TPM binding in slot $slot..."
    clevis luks unbind -d "$dev" -s "$slot" -f
done

echo
echo "Bindings on $dev:"
clevis luks list -d "$dev" | sed 's/^/  /'
echo
echo "Done. Run 6-pre-reboot-tests.sh to confirm."
