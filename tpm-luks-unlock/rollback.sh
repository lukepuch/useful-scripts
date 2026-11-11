#!/usr/bin/env bash
# rollback.sh — undo TPM2 auto-unlock: remove every clevis TPM binding from
# the LUKS volume. The machine goes back to asking for the passphrase at boot.
#
# Usage:
#   rollback.sh    (needs sudo)
#
# Only removes the TPM key slot(s) and their tokens. The passphrase slot is
# not touched, and the clevis packages stay installed (harmless with nothing
# bound); the commands to remove them are printed at the end.

set -euo pipefail

LUKS_DEV=/dev/disk/by-uuid/d4129ba6-8abf-46f6-a410-b6ec9cbf364f

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

dev=$(readlink -f "$LUKS_DEV")
slots=$(clevis luks list -d "$dev" | sed -n 's/^\([0-9]\+\): tpm2 .*/\1/p')

if [[ -z $slots ]]; then
    echo "No TPM bindings on $dev — nothing to remove."
else
    for slot in $slots; do
        echo "Removing TPM binding in slot $slot..."
        clevis luks unbind -d "$dev" -s "$slot" -f
    done
fi

cat <<EOF

Done. $dev now unlocks with the passphrase only.

To also remove clevis (this rebuilds the initrd without it):
  sudo apt purge clevis clevis-luks clevis-tpm2 clevis-initramfs

To put back the initrd saved in step 1:
  sudo cp -a /boot/initrd.img-$(uname -r).pre-clevis /boot/initrd.img-$(uname -r)
EOF
