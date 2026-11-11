#!/usr/bin/env bash
# 3-install-clevis.sh — step 3 of setting up TPM2 auto-unlock: install clevis
# and its initramfs-tools integration.
#
# Usage:
#   3-install-clevis.sh    (needs sudo)
#
# apt shows the package list and asks before installing. Installing
# clevis-initramfs rebuilds the initrd, so this refuses to run until the
# step 1 backups exist. Nothing is bound to the TPM yet; the passphrase
# prompt at boot behaves exactly as before.

set -euo pipefail

INITRD_BACKUP=/boot/initrd.img-$(uname -r).pre-clevis

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

if ! compgen -G '/root/luks-header-*.img' >/dev/null || [[ ! -e $INITRD_BACKUP ]]; then
    echo "Step 1 backups not found — run 1-backup-luks-header-and-initrd.sh first." >&2
    exit 1
fi

apt-get update
apt-get install clevis clevis-luks clevis-tpm2 clevis-initramfs

echo
echo "Done. Next: 4-bind-tpm.sh"
