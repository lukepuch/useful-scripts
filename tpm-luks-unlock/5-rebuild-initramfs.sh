#!/usr/bin/env bash
# 5-rebuild-initramfs.sh — step 5 of setting up TPM2 auto-unlock: rebuild the
# initrd for the running kernel and confirm clevis is inside it.
#
# Usage:
#   5-rebuild-initramfs.sh    (needs sudo)
#
# Only the running kernel's initrd is rebuilt, so the older kernel's entry in
# the GRUB menu stays as an untouched fallback. Installing clevis-initramfs
# in step 3 already rebuilt the initrd once; this makes sure it is current
# and checks the result.

set -euo pipefail

KERNEL=$(uname -r)
INITRD=/boot/initrd.img-$KERNEL

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

if [[ ! -e $INITRD.pre-clevis ]]; then
    echo "$INITRD.pre-clevis not found — run 1-backup-luks-header-and-initrd.sh first." >&2
    exit 1
fi

update-initramfs -u -k "$KERNEL"

echo
files=$(lsinitramfs "$INITRD")
if ! grep -q 'clevis-decrypt-tpm2' <<<"$files"; then
    echo "clevis is NOT in $INITRD — do not reboot expecting auto-unlock." >&2
    exit 1
fi
echo "clevis is in $INITRD:"
grep -E 'clevis-decrypt-tpm2$|scripts/.*clevis|libtss2-tcti-device' <<<"$files" | sed 's/^/  /'

echo
echo "Done. Next: 6-pre-reboot-tests.sh"
