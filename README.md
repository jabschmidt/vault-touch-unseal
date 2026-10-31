# vault-touch-unseal

Unseal a local HashiCorp Vault on macOS with one touch of a YubiKey at login.

## The problem

Vault starts sealed every time it restarts. Until someone unseals it, it hands out no secrets, so everything that depends on it stops. On a personal machine that means every reboot, not a rare event.

The usual ways out each give something up:

- **Type the key after every reboot.** Safe, but tedious, and easy to forget until a task fails with a seal error.
- **Keep the key in a file, a script or a keychain item.** Convenient, but any process running as you may be able to read it and unseal, which defeats the seal. This matters more now that AI agents and automation run under your account.
- **Use Vault's auto-unseal.** It needs a cloud KMS, an HSM or a second Vault, which is a lot for one machine at home. It also unseals with no person involved.

## The approach

Keep a person in the loop, but reduce the job to one touch. The unseal key is stored encrypted with AES-256 under a secret from the YubiKey's FIDO2 `hmac-secret` extension. The YubiKey produces that secret only after a physical touch, so software alone cannot unseal, including an AI agent or any other process running as you. If you are not there to touch it, Vault stays sealed, and the manual unseal still works.

This suits one person running Vault on their own Mac. It is not built for shared or production Vault clusters.

## Status

The original version of these scripts runs on one iMac with macOS 26.6, Vault 2.2.1 and a YubiKey Security Key NFC. Real reboots there proved three outcomes: touched and unsealed, key removed, and no touch. In the last two, Vault stayed sealed until the manual unseal. The YubiKey refused the secret when asked to skip the touch.

This repo is a cleaned-up copy with machine-specific values turned into settings. It has passed a syntax check, but it has not been through a real setup and reboot. Test it before you rely on it, and keep your unseal key where you can reach it.

## Requirements

- macOS, with a Vault server you run yourself and a GUI login session
- A single-key seal (`key-threshold=1`). This tool submits one key, so a threshold above 1 will not unseal
- A YubiKey with FIDO2 and `hmac-secret`. The script matches Yubico's USB vendor ID, 0x1050
- `libfido2` (`brew install libfido2`), which provides `fido2-token`, `fido2-cred` and `fido2-assert`

## Set up

    zsh vault_touch_setup.sh

It asks once, hidden, for the unseal key, then takes three touches. It installs a LaunchAgent that points at this folder, so keep the folder where it is, or run setup again after moving it.

Then reboot, log in, and touch the key when the notification appears.

## What happens at login

The job waits up to 120 seconds for Vault to answer and exits if Vault is already unsealed. Otherwise it looks for the key for 30 seconds, shows a notification, and tries four times, about 30 seconds each.

Read the result in `~/Library/Logs/vault-touch-unseal.log`. The log holds states, never a secret.

| State | Meaning |
|---|---|
| UNSEALED | Worked |
| ALREADY UNSEALED | Nothing to do |
| WAITING for touch | Asking the key now |
| NO TOUCH | No touch in time, Vault stays sealed |
| NO KEY | YubiKey not found, Vault stays sealed |
| NO LIBFIDO2 | Tools not found |
| UNREACHABLE | Vault did not answer |
| NOT SET UP | State files are missing |
| DECRYPT FAILED | Wrong key or damaged file, nothing was sent to Vault |
| STILL SEALED | Vault refused the key, which usually means it changed. Redo setup |

On anything but the first three, use `vault operator unseal`. It always works.

## Security limits

- One touch is the whole check, because the credential uses no PIN. Touch the key only right after login. A blink at any other time means do not touch it.
- If the key stays plugged in, a thief who also has your login password could unseal. FileVault and that password are the protection.
- Backups of the state folder hold only the encrypted file, which is useless without the YubiKey.
- Losing the key loses only this shortcut. Keep your unseal key and recovery material stored separately.

## Settings

| Variable | Default | Purpose |
|---|---|---|
| `VAULT_ADDR` | `http://127.0.0.1:8200` | Vault address |
| `VTU_STATE` | `~/.vault-touch-unseal` | State folder |
| `VTU_RP` | `vault-touch-unseal.local` | FIDO2 relying party name, fixed at setup |
| `VTU_WAIT` | `120` | Seconds to wait for Vault |
| `VTU_TOUCHES` | `4` | Touch attempts |
| `FIDO_BIN` | Homebrew bin | Folder holding the fido2 tools |

## Redo or remove

These delete the encrypted file:

    launchctl bootout gui/$(id -u)/local.vault-touch-unseal
    rm ~/Library/LaunchAgents/local.vault-touch-unseal.plist
    rm -rf ~/.vault-touch-unseal

Run setup again, or stop there to go back to manual unseal.
