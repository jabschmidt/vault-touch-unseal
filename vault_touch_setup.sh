#!/bin/zsh
# One-time setup for vault_touch_unseal.sh. Run it yourself, in your own terminal.
#
# Makes a FIDO2 credential on the YubiKey, encrypts the unseal key with the secret only the
# YubiKey can produce, proves it decrypts, and installs the login job. Takes three touches.
# Prints no secret. The manual `vault operator unseal` keeps working.
#
# Usage: zsh vault_touch_setup.sh     (prompts once, hidden, for the unseal key)
#
# Optional environment: VAULT_ADDR, VTU_STATE, VTU_RP, FIDO_BIN. Set VTU_STATE and VTU_RP in
# the plist too if you change them, because the login job must use the same values.

set -euo pipefail
umask 077

ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
STATE=${VTU_STATE:-$HOME/.vault-touch-unseal}
RP=${VTU_RP:-vault-touch-unseal.local}
HERE=${0:A:h}
LABEL=local.vault-touch-unseal
TEMPLATE=$HERE/$LABEL.plist.template
INSTALLED=$HOME/Library/LaunchAgents/$LABEL.plist
LOG=$HOME/Library/Logs/vault-touch-unseal.log
MAGIC=VTU1:

if [[ -z ${FIDO_BIN:-} ]]; then
  FIDO_BIN=""
  for d in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x $d/fido2-assert ]]; then
      FIDO_BIN=$d
      break
    fi
  done
fi

[[ -n $FIDO_BIN ]] || { print -u2 "STOP: libfido2 not found, run: brew install libfido2"; exit 1; }
[[ -t 0 ]] || { print -u2 "STOP: run this in your own terminal"; exit 1; }
[[ ! -e $STATE ]] || { print -u2 "STOP: $STATE already exists, see the README to redo setup"; exit 1; }
[[ -f $TEMPLATE ]] || { print -u2 "STOP: $TEMPLATE missing"; exit 1; }
dev=$("$FIDO_BIN/fido2-token" -L | /usr/bin/grep 'vendor=0x1050' | /usr/bin/head -1 | /usr/bin/sed -E 's/: vendor.*//')
[[ -n $dev ]] || { print -u2 "STOP: YubiKey not found"; exit 1; }

rand() { /bin/dd if=/dev/urandom bs=32 count=1 2>/dev/null | /usr/bin/base64; }
assert() {  # prints the hmac secret; needs a touch
  local out
  out=$(print -rl -- "$(rand)" "$RP" "$cred" "$salt" | "$FIDO_BIN/fido2-assert" -G -h -t up=true "$dev")
  print -r -- "${${(f)out}[5]}"
}

read -rs "key?Vault unseal key: "; print
trap 'unset key derived back 2>/dev/null' EXIT
(( ${#key} >= 20 )) || { print -u2 "STOP: that does not look like an unseal key"; exit 1; }

tmp=$STATE.new
/bin/rm -rf "$tmp"; /bin/mkdir -m 700 "$tmp"

print "Touch 1 of 3: touch the YubiKey when it blinks."
made=$(print -rl -- "$(rand)" "$RP" vault-unseal "$(rand)" | "$FIDO_BIN/fido2-cred" -M -h "$dev" es256)
cred=${${(f)made}[5]}
salt=$(rand)
print -r -- "$cred" > "$tmp/cred.id"
print -r -- "$salt" > "$tmp/salt"

print "Touch 2 of 3: touch it again."
derived=$(assert)
[[ -n $derived ]] || { print -u2 "STOP: the key returned no secret"; exit 1; }
print -rn -- "$MAGIC$key" | /usr/bin/openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 -salt -out "$tmp/unseal.enc" -pass fd:3 3< <(print -rn -- "$derived")

print "Touch 3 of 3: one more, to prove it decrypts."
derived=$(assert)
back=$(/usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 -in "$tmp/unseal.enc" -pass fd:3 3< <(print -rn -- "$derived"))
[[ $back == "$MAGIC$key" ]] || { /bin/rm -rf "$tmp"; print -u2 "STOP: decrypt check failed, nothing installed"; exit 1; }

/bin/mv "$tmp" "$STATE"
/usr/bin/sed -e "s|@SCRIPT@|$HERE/vault_touch_unseal.sh|" -e "s|@ADDR@|$ADDR|" -e "s|@LOG@|$LOG|g" "$TEMPLATE" > "$INSTALLED"
/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$(id -u)" "$INSTALLED"

print "DONE: encrypted key in $STATE, login job installed. No secret printed."
print "Prove it: reboot, log in, touch the YubiKey when it blinks."
