# tpm-luks-unlock

Set up TPM2 auto-unlock for the LUKS-encrypted root drive on this headless server, so it boots unattended after a power outage. The existing passphrase stays as the fallback.

Run the numbered steps in order. Steps 2 and 7 are done by hand at the console.

| Step | What | How |
|---|---|---|
| 0 | Check the machine is ready | `./0-prerequisites.sh` |
| 1 | Back up the LUKS header and initrd | `./1-backup-luks-header-and-initrd.sh` |
| 2 | Firmware: Secure Boot, BIOS password, boot options | by hand, see below |
| 3 | Install clevis | `./3-install-clevis.sh` |
| 4 | Bind the volume to the TPM | `./4-bind-tpm.sh` |
| 5 | Rebuild the initrd | `./5-rebuild-initramfs.sh` |
| 6 | Test before rebooting | `./6-pre-reboot-tests.sh` |
| 7 | Reboot and test | by hand, see below |
| 8 | Optional hardening | not scripted, see below |

Afterwards: `./reseal.sh` when the TPM stops unlocking, `./rollback.sh` to undo it all.

Scripts that need root call `sudo` themselves. None of them reads your LUKS passphrase; where it is needed, `clevis` or `cryptsetup` prompts for it directly.

## This system

- Ubuntu 24.04 LTS on an HP EliteDesk 805 G6 Mini.
- `nvme0n1p3` is LUKS2 (UUID `d4129ba6-8abf-46f6-a410-b6ec9cbf364f`) → LVM → `/`. The passphrase is in key slot 0.
- `/boot` (`nvme0n1p2`) and the ESP (`nvme0n1p1`) are unencrypted.
- initramfs-tools, signed shim → GRUB, discrete Infineon TPM 2.0.

The scripts have the LUKS UUID hardcoded. They are written for this machine.

## Why clevis and not systemd-cryptenroll

Ubuntu 24.04's initramfs-tools has no TPM2 support in its unlock script, so a `tpm2-device=` option in `/etc/crypttab` does nothing at boot. Using `systemd-cryptenroll` would mean replacing initramfs-tools with dracut. clevis hooks into initramfs-tools as it is, needs no `crypttab` change, and leaves the normal passphrase prompt in place as the fallback.

clevis comes from `universe`, so it gets community security support unless the machine has Ubuntu Pro.

## What this protects, and what it doesn't

The TPM releases the key only when PCR 7 matches the value it had at bind time. PCR 7 is a fingerprint of the Secure Boot state: on or off, the trusted and revoked key lists, and which keys signed what booted.

It protects against:

- The disk being pulled, sold, or returned under warranty. Without this machine's TPM there is no key.
- Booting an unsigned or differently-signed operating system on this machine.
- A casual thief, who gets a login prompt and nothing else.

It does not protect against:

- **A signed Ubuntu live USB.** It uses the same signing chain and so gets the same PCR 7. Mitigation: disable USB and network boot and set a BIOS password (step 2).
- **Editing the kernel command line in GRUB** (for example `init=/bin/bash`), or modifying the unsigned initrd on the unencrypted `/boot`. The command line and initrd are not part of PCR 7. A GRUB password stops the casual version (step 8).
- **Anything once the machine is running.** The disk is unlocked; security then rests on logins and network services.

Binding PCRs 8 and 9 as well would cover the command line and initrd, but those change with every kernel update, and the machine would stop at the passphrase prompt after each one.

## Step 0: check the machine is ready

```bash
./0-prerequisites.sh
```

Read-only. Prints `OK`, `WARN`, `FAIL` or `SKIP` per check and exits 1 if anything failed. `sudo` asks for your password for two of the checks (key slots, kernel signature).

Before step 2, expect one `FAIL` (Secure Boot disabled) and warnings for USB/network boot, GRUB password and dropbear.

## Step 1: back up the LUKS header and initrd

```bash
./1-backup-luks-header-and-initrd.sh
```

Writes two files and refuses to overwrite either:

- `/root/luks-header-nvme0n1p3-<date>.img`
- `/boot/initrd.img-<kernel>.pre-clevis`

Then copy the header backup off the machine; a copy inside the encrypted volume can't help if the header is damaged. From another machine:

```bash
ssh -t <server> sudo cat /root/luks-header-nvme0n1p3-<date>.img > luks-header.img
```

Compare its `sha256sum` with the one the script printed.

## Step 2: firmware settings (by hand)

Needs a monitor and keyboard. The menu names are from HP's business BIOS and may differ slightly.

1. Reboot and tap **F10** at power-on (or Esc, then F10).
2. Security → *Create BIOS Administrator Password*. Store it in a password manager.
3. Security → *Secure Boot Configuration* → set *Configure Legacy Support and Secure Boot* to **Legacy Support Disable and Secure Boot Enable**. Leave the key-management options alone.
4. Advanced → *Boot Options* → untick **USB Storage Boot** and **Network (PXE) Boot**.
5. Same screen: set *After Power Loss* to **Power On**.
6. Leave Security → *TPM Embedded Security* alone, and decline anything that offers to clear the TPM.
7. Main → *Save Changes and Exit*.
8. The next boot asks you to type a 4-digit code to confirm the Secure Boot change. Type it and press Enter.
9. Enter the LUKS passphrase as usual.
10. Run `./0-prerequisites.sh` again. Secure Boot should be `OK`.

Notes:

- Secure Boot must be on before step 4, because toggling it changes PCR 7.
- Disabling PXE boot does not disable the network card. Leave the *Embedded LAN Controller* enabled.
- With USB boot disabled, booting a rescue USB later means going into the BIOS with the password and re-enabling it. That does not affect the TPM binding.
- If a "Security Violation" screen appears instead of GRUB, go back into F10 and turn Secure Boot off again. Nothing on disk has changed.

## Step 3: install clevis

```bash
./3-install-clevis.sh
```

Installs `clevis`, `clevis-luks`, `clevis-tpm2` and `clevis-initramfs`. apt asks before installing. Refuses to run if the step 1 backups are missing, because the install rebuilds the initrd.

## Step 4: bind the volume to the TPM

```bash
./4-bind-tpm.sh
```

Runs `clevis luks bind` with `{"pcr_bank":"sha256","pcr_ids":"7"}`. clevis prompts for the existing passphrase, then adds its own key slot and token. Slot 0 is not touched.

Refuses to run if Secure Boot is off, the header backup is missing, or the volume is already bound.

## Step 5: rebuild the initrd

```bash
./5-rebuild-initramfs.sh
```

Rebuilds the initrd for the running kernel only and checks clevis is inside it. The older kernel's GRUB entry is left as an untouched fallback.

## Step 6: test before rebooting

```bash
./6-pre-reboot-tests.sh
```

Read-only. Checks that:

- both backups exist;
- Secure Boot is enabled;
- there is a `tpm2` binding that includes PCR 7, and the TPM can unseal its key right now;
- a non-TPM key slot still exists and your passphrase unlocks it (cryptsetup prompts for it);
- clevis is in the initrd.

Don't rely on unattended boot until this passes.

## Step 7: reboot and test (by hand)

Keep the monitor and keyboard attached for the first reboot.

1. `sudo reboot`. Success is reaching the login prompt with nobody typing. The passphrase prompt may show briefly before clevis answers it.
2. If it stays at the passphrase prompt, type the passphrase. The system is fine; the TPM unlock just didn't work. Run `./6-pre-reboot-tests.sh` to see why.
3. Once a normal reboot works, do the real test: shut down, pull the power, plug it back in. It should power on by itself and come up unattended.
4. Reboot once more and pick the older kernel from the GRUB menu (hold Esc at boot) to confirm that entry works too.

## Step 8: optional hardening (not scripted)

Both of these change boot configuration and deserve their own review, so there is no script yet.

- **GRUB password.** Stops command-line editing at the console. The normal menu entries must be marked `--unrestricted`, or GRUB will ask for the password on every boot and break unattended start.
- **dropbear-initramfs.** A small SSH server in the initrd, so the passphrase can be typed remotely when the TPM refuses. It listens on the LAN only; Tailscale is not up until the disk is unlocked.

## When the TPM stops unlocking

Ordinary kernel and package updates don't change PCR 7. These do:

- a revocation list (dbx) update, from a firmware update or fwupd;
- a signing key rotation, when Ubuntu ships a shim signed under a newer key;
- a BIOS update or reset that turns Secure Boot off or resets its keys;
- Secure Boot being toggled, or the TPM being cleared;
- a motherboard swap.

The machine then waits at the passphrase prompt. Type the passphrase at the console, make sure Secure Boot is still on, and re-seal:

```bash
./reseal.sh
./6-pre-reboot-tests.sh
```

`reseal.sh` adds a new TPM binding against the current PCR 7 and then removes the old one. clevis prompts for the passphrase.

## Rollback

Remove the TPM binding and go back to passphrase-only:

```bash
./rollback.sh
```

Then, if wanted:

```bash
# remove clevis; this rebuilds the initrd without it
sudo apt purge clevis clevis-luks clevis-tpm2 clevis-initramfs

# or put back the initrd saved in step 1
sudo cp -a /boot/initrd.img-$(uname -r).pre-clevis /boot/initrd.img-$(uname -r)
```

If the new initrd won't boot, hold Esc at power-on for the GRUB menu and pick the older kernel under *Advanced options*.

Last resort, if the LUKS header itself is damaged: boot a live USB (re-enable USB boot in the BIOS first) and restore the backup from step 1. This overwrites every key slot with the backed-up state.

```bash
sudo cryptsetup luksHeaderRestore /dev/nvme0n1p3 --header-backup-file luks-header.img
```
