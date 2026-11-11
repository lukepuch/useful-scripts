#!/usr/bin/env bash
# 0-prerequisites.sh — step 0 of setting up TPM2 auto-unlock: check whether
# this machine is ready. Read-only; changes nothing.
#
# Usage:
#   0-prerequisites.sh
#
# Runs as you. Two checks (LUKS key slots, kernel signature) need root, so
# sudo will ask for your password for just those two commands. To skip them,
# press Enter at each password prompt until sudo gives up; they show as SKIP.
# (Ctrl-C at the prompt stops the whole script.)
#
# Each line is OK, WARN (works, but weakens what the TPM binding protects)
# or FAIL (fix before binding). Exits 1 if anything is FAIL.

# No -e or pipefail: a failed check is reported, not fatal, and `grep -q`
# closing a pipe early must not count as a failure.
set -u

LUKS_DEV=/dev/disk/by-uuid/d4129ba6-8abf-46f6-a410-b6ec9cbf364f
EFIVARS=/sys/firmware/efi/efivars
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
TPM=/sys/class/tpm/tpm0

# Colour only when writing to a terminal, so piped or redirected output stays
# plain. Set NO_COLOR=1 to turn it off.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' DIM=$'\e[2m' RESET=$'\e[0m'
else
    GREEN='' YELLOW='' RED='' DIM='' RESET=''
fi

fails=0
ok()   { printf '  %sOK%s    %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$*"; fails=$((fails + 1)); }
skip() { printf '  %sSKIP%s  %s\n' "$DIM" "$RESET" "$*"; }

# Prefix for the two commands that need root.
SUDO=()
[[ $EUID -ne 0 ]] && SUDO=(sudo)

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# Value byte of a UEFI variable (the first 4 bytes are attributes).
efivar() { od -An -t u1 -j4 -N1 "$EFIVARS/$1-$EFI_GLOBAL" 2>/dev/null | tr -d ' '; }

echo "== firmware =="
if [[ -d /sys/firmware/efi ]]; then
    ok "booted via UEFI"
else
    fail "not booted via UEFI — PCR 7 binding needs UEFI"
fi

if [[ $(efivar SecureBoot) == 1 ]]; then
    ok "Secure Boot is enabled"
else
    fail "Secure Boot is disabled — enable it in firmware before binding (toggling it changes PCR 7)"
fi

if [[ $(efivar SetupMode) == 0 ]]; then
    ok "Secure Boot keys are enrolled (not in setup mode)"
else
    fail "firmware is in setup mode — no Secure Boot keys enrolled"
fi

echo
echo "== boot order =="
order=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: //p')
if [[ -z $order ]]; then
    skip "could not read boot order from efibootmgr"
else
    removable=0
    for id in ${order//,/ }; do
        label=$(efibootmgr | sed -n "s/^Boot$id\*\{0,1\} *//p" | cut -f1)
        if grep -qiE 'usb|network|pxe|ipv[46]' <<<"$label"; then
            warn "Boot$id is bootable: $label"
            removable=1
        fi
    done
    if [[ $removable == 0 ]]; then
        ok "no USB or network entries in the boot order"
    else
        echo "        A signed live USB gets the same PCR 7 and could unseal the key."
        echo "        Disable USB/network boot in firmware and set a BIOS setup password."
    fi
fi

echo
echo "== TPM =="
if [[ $(cat $TPM/tpm_version_major 2>/dev/null) == 2 ]]; then
    ok "TPM 2.0 present"
else
    fail "no TPM 2.0 device found"
fi

if [[ -r $TPM/pcr-sha256/7 ]]; then
    ok "PCR 7 (sha256): $(cat $TPM/pcr-sha256/7)"
else
    fail "no sha256 PCR bank"
fi

echo
echo "== disk encryption =="
if [[ $(lsblk -dno FSVER "$LUKS_DEV" 2>/dev/null) == 2 ]]; then
    ok "$(readlink -f "$LUKS_DEV") is LUKS2"
else
    fail "$LUKS_DEV is missing or not LUKS2"
fi

if ! dump=$("${SUDO[@]}" cryptsetup luksDump "$LUKS_DEV" 2>/dev/null); then
    skip "key slots — needs root"
else
    slots=$(grep -cE '^ +[0-9]+: luks2' <<<"$dump")
    if (( slots < 32 )); then
        ok "$slots key slot(s) in use, room for the TPM slot"
    else
        fail "all 32 key slots are in use"
    fi
    if grep -q clevis <<<"$dump"; then
        warn "a clevis token is already present — already bound?"
    else
        ok "no clevis token yet"
    fi
fi

echo
echo "== boot chain =="
if installed initramfs-tools && installed cryptsetup-initramfs; then
    ok "initramfs-tools with cryptsetup-initramfs"
else
    fail "expected initramfs-tools + cryptsetup-initramfs (clevis-initramfs hooks into these)"
fi

if installed shim-signed && installed grub-efi-amd64-signed; then
    ok "signed shim and GRUB installed"
else
    fail "shim-signed / grub-efi-amd64-signed missing — won't boot under Secure Boot"
fi

if ! sig=$("${SUDO[@]}" sbverify --list "/boot/vmlinuz-$(uname -r)" 2>/dev/null); then
    skip "kernel signature — needs root"
elif grep -q Canonical <<<"$sig"; then
    ok "running kernel is signed by Canonical"
else
    fail "running kernel has no Canonical signature — won't boot under Secure Boot"
fi

# Taint bits 12 (out-of-tree module) and 13 (unsigned module).
if (( $(cat /proc/sys/kernel/tainted) & 12288 )) || [[ -d /var/lib/dkms ]]; then
    fail "out-of-tree or unsigned kernel modules in use — they won't load under Secure Boot"
else
    ok "no out-of-tree or unsigned kernel modules"
fi

if grep -rqs password_pbkdf2 /etc/grub.d; then
    ok "GRUB password is set"
else
    warn "no GRUB password — the kernel command line can be edited at the console"
fi

echo
echo "== packages =="
for p in clevis clevis-luks clevis-tpm2 clevis-initramfs; do
    if installed "$p"; then
        ok "$p installed"
    elif apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
        ok "$p available from apt (not installed yet)"
    else
        fail "$p not available from apt — is 'universe' enabled?"
    fi
done

if installed dropbear-initramfs; then
    ok "dropbear-initramfs installed (remote passphrase entry)"
else
    warn "no dropbear-initramfs — if the TPM refuses, the passphrase must be typed at the console"
fi

echo
if (( fails )); then
    echo "${RED}$fails check(s) FAILED${RESET} — fix those before binding."
    exit 1
fi
echo "No failures. Review any WARN lines, then carry on with step 1."
