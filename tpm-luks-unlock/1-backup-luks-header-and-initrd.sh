#!/usr/bin/env bash
# 1-backup-luks-header-and-initrd.sh — step 1 of setting up TPM2 auto-unlock:
# back up the LUKS header and the current initrd before anything is changed.
#
# Usage:
#   1-backup-luks-header-and-initrd.sh    (needs sudo)
#
# Writes two files and refuses to overwrite either, so rerunning it later
# can't replace a known-good backup with a post-change one:
#   /root/luks-header-<partition>-<date>.img   copy this OFF the machine
#   /boot/initrd.img-<kernel>.pre-clevis       known-good initrd to fall back to

set -euo pipefail

LUKS_DEV=/dev/disk/by-uuid/d4129ba6-8abf-46f6-a410-b6ec9cbf364f
INITRD=/boot/initrd.img-$(uname -r)

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

header_backup=/root/luks-header-$(basename "$(readlink -f "$LUKS_DEV")")-$(date +%F).img
initrd_backup=$INITRD.pre-clevis

for f in "$header_backup" "$initrd_backup"; do
    if [[ -e $f ]]; then
        echo "$f already exists — not overwriting. Move it aside to take a new backup." >&2
        exit 1
    fi
done

echo "Backing up LUKS header of $(readlink -f "$LUKS_DEV")..."
cryptsetup luksHeaderBackup "$LUKS_DEV" --header-backup-file "$header_backup"

echo "Backing up $INITRD..."
cp -a "$INITRD" "$initrd_backup"

echo
sha256sum "$header_backup" "$initrd_backup"
echo
echo "Done. Now copy $header_backup somewhere off this machine —"
echo "a header backup inside the encrypted volume can't help if the header is damaged."
