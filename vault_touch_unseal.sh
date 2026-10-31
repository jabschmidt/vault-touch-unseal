#!/bin/zsh
# Unseal a local HashiCorp Vault at login with one touch of a YubiKey. Run by the LaunchAgent
# that vault_touch_setup.sh installs, once per login.
#
# The unseal key sits on disk encrypted with a secret that only the YubiKey can produce
# (FIDO2 hmac-secret), and the key refuses to produce it without a physical touch. The
# decrypted key lives in this process only, reaches curl over stdin, and is never logged
# or passed as an argument.

set -uo pipefail
umask 077

ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
STATE=${VTU_STATE:-$HOME/.vault-touch-unseal}
WAIT=${VTU_WAIT:-120}
TOUCHES=${VTU_TOUCHES:-4}
RP=${VTU_RP:-vault-touch-unseal.local}
MAGIC=VTU1:

log() { print -r -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"; }
notify() {
  [[ -n ${VTU_QUIET:-} ]] && return 0
  /usr/bin/osascript -e "display notification \"$1\" with title \"Vault\" sound name \"Glass\"" 2>/dev/null
}
sealed_state() {  # prints true or false, or nothing if Vault is not answering
  /usr/bin/curl -s --max-time 3 "$ADDR/v1/sys/seal-status" 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(str(json.load(sys.stdin)["sealed"]).lower())' 2>/dev/null
}

# launchd gives a short PATH, so look in both Homebrew locations.
if [[ -z ${FIDO_BIN:-} ]]; then
  FIDO_BIN=""
  for d in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x $d/fido2-assert ]]; then
      FIDO_BIN=$d
      break
    fi
  done
fi
[[ -n $FIDO_BIN ]] || { log "NO LIBFIDO2: fido2-assert not found"; notify "libfido2 not found. Unseal by hand."; exit 1; }

for f in cred.id salt unseal.enc; do
  [[ -s $STATE/$f ]] || { log "NOT SET UP: $STATE/$f missing"; exit 0; }
done

state=""
for (( t = 0; t < WAIT; t += 5 )); do
  state=$(sealed_state)
  [[ -n $state ]] && break
  sleep 5
done
[[ -n $state ]] || { log "UNREACHABLE: Vault did not answer in ${WAIT}s"; notify "Vault is not answering."; exit 1; }
[[ $state == true ]] || { log "ALREADY UNSEALED: nothing to do"; exit 0; }

dev=""
for (( t = 0; t < 30; t += 5 )); do
  dev=$("$FIDO_BIN/fido2-token" -L 2>/dev/null | /usr/bin/grep 'vendor=0x1050' | /usr/bin/head -1 | /usr/bin/sed -E 's/: vendor.*//')
  [[ -n $dev ]] && break
  sleep 5
done
[[ -n $dev ]] || { log "NO KEY: YubiKey not found"; notify "YubiKey not found. Unseal by hand."; exit 1; }

log "WAITING for touch"
notify "Touch your YubiKey to unseal."
derived=""
for (( i = 1; i <= TOUCHES; i++ )); do
  out=$(print -rl -- "$(/bin/dd if=/dev/urandom bs=32 count=1 2>/dev/null | /usr/bin/base64)" "$RP" "$(<$STATE/cred.id)" "$(<$STATE/salt)" \
    | "$FIDO_BIN/fido2-assert" -G -h -t up=true "$dev" 2>/dev/null)
  if [[ $? -eq 0 ]]; then
    derived=${${(f)out}[5]:-}
    [[ -n $derived ]] && break
  fi
done
[[ -n $derived ]] || { log "NO TOUCH after $TOUCHES tries"; notify "No touch. Unseal by hand."; exit 1; }

plain=$(/usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 -in "$STATE/unseal.enc" -pass fd:3 3< <(print -rn -- "$derived") 2>/dev/null)
unset derived out
if [[ $plain != ${MAGIC}* ]]; then
  unset plain
  log "DECRYPT FAILED: wrong key or damaged file, nothing sent to Vault"
  notify "Could not decrypt. Unseal by hand."
  exit 1
fi

print -rn -- "{\"key\":\"${plain#$MAGIC}\"}" \
  | /usr/bin/curl -s --max-time 10 -X PUT -H 'Content-Type: application/json' --data-binary @- "$ADDR/v1/sys/unseal" >/dev/null
unset plain

if [[ $(sealed_state) == false ]]; then
  log "UNSEALED"
  notify "Unsealed."
  exit 0
fi
log "STILL SEALED: Vault did not accept the key"
notify "Still sealed. Unseal by hand."
exit 1
