#!/usr/bin/env bash
# 6-pre-reboot-tests.sh — step 6 of setting up TPM2 auto-unlock: confirm the
# TPM can unseal the key and the passphrase still works, before rebooting.
# Read-only; changes nothing.
#
# Usage:
#   6-pre-reboot-tests.sh    (needs sudo; cryptsetup prompts for your LUKS
#                             passphrase once, to prove the fallback works)
#
# Each line is OK or FAIL. Exits 1 if anything is FAIL — don't reboot
# unattended until it passes.

# No -e or pipefail: a failed check is reported, not fatal.
set -u

LUKS_DEV=/dev/disk/by-uuid/d4129ba6-8abf-46f6-a410-b6ec9cbf364f
INITRD=/boot/initrd.img-$(uname -r)

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# Colour only when writing to a terminal. Set NO_COLOR=1 to turn it off.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    GREEN=$'\e[32m' RED=$'\e[31m' RESET=$'\e[0m'
else
    GREEN='' RED='' RESET=''
fi

fails=0
ok()   { printf '  %sOK%s    %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$*"; fails=$((fails + 1)); }

dev=$(readlink -f "$LUKS_DEV")

echo "== backups =="
if compgen -G '/root/luks-header-*.img' >/dev/null; then
    ok "LUKS header backup: $(compgen -G '/root/luks-header-*.img' | tr '\n' ' ')"
else
    fail "no LUKS header backup in /root"
fi
if [[ -e $INITRD.pre-clevis ]]; then
    ok "initrd backup: $INITRD.pre-clevis"
else
    fail "no initrd backup at $INITRD.pre-clevis"
fi

echo
echo "== Secure Boot =="
if [[ $(mokutil --sb-state 2>/dev/null) == *enabled* ]]; then
    ok "Secure Boot is enabled"
else
    fail "Secure Boot is not enabled"
fi

echo
echo "== TPM binding =="
# Lines look like:  1: tpm2 '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"7"}'
bindings=$(clevis luks list -d "$dev" 2>/dev/null | grep ': tpm2 ')
clevis_slots=()
if [[ -z $bindings ]]; then
    fail "no tpm2 binding on $dev"
else
    while IFS= read -r line; do
        slot=${line%%:*}
        clevis_slots+=("$slot")
        if grep -q '"pcr_ids":"[^"]*\b7\b' <<<"$line"; then
            ok "slot $slot is bound to tpm2 including PCR 7"
        else
            fail "slot $slot is bound to tpm2 but not to PCR 7: $line"
        fi
        if clevis luks pass -d "$dev" -s "$slot" >/dev/null 2>&1; then
            ok "TPM unsealed the key for slot $slot"
        else
            fail "TPM could not unseal the key for slot $slot"
        fi
    done <<<"$bindings"
fi

echo
echo "== passphrase fallback =="
all_slots=$(cryptsetup luksDump "$dev" | sed -n 's/^ \+\([0-9]\+\): luks2$/\1/p')
other_slots=()
for s in $all_slots; do
    [[ " ${clevis_slots[*]-} " == *" $s "* ]] || other_slots+=("$s")
done
if (( ${#other_slots[@]} )); then
    ok "non-TPM key slot(s) still present: ${other_slots[*]}"
    echo "        Enter your LUKS passphrase to prove it still unlocks the volume:"
    if cryptsetup open --test-passphrase --key-slot "${other_slots[0]}" "$dev"; then
        ok "passphrase unlocks slot ${other_slots[0]}"
    else
        fail "passphrase did not unlock slot ${other_slots[0]}"
    fi
else
    fail "no key slot other than the TPM one — the passphrase fallback is gone"
fi

echo
echo "== initrd =="
if grep -q 'clevis-decrypt-tpm2' <<<"$(lsinitramfs "$INITRD" 2>/dev/null)"; then
    ok "clevis is in $INITRD"
else
    fail "clevis is not in $INITRD — run 5-rebuild-initramfs.sh"
fi

echo
if (( fails )); then
    echo "${RED}$fails check(s) FAILED${RESET} — don't rely on unattended boot yet."
    exit 1
fi
echo "All checks passed. Reboot with a monitor and keyboard attached (step 7)."
