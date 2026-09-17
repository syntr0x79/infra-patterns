#!/usr/bin/env bash
# Encrypt or decrypt the working set of secrets as a single archive.
#
# The problem this solves: a stack with twenty services has one .env plus a
# secrets/ directory of certificates and JSON files. None of it can go in git.
# So it lives on one laptop, and onboarding a second engineer — or rebuilding
# after a disk failure — becomes an afternoon of asking people for files.
#
# The bundle is a durable, committable artifact: AES-256-CBC with PBKDF2 and a
# salt, opened by one passphrase. The plaintext sources stay gitignored; only
# the ciphertext is tracked.
#
# This is deliberately NOT a secret manager. It is the thing that gets a new
# machine to a working state, and the escape hatch for when Vault is the thing
# that is down. Runtime secret delivery is Vault's job — see VAULT.md.
#
#   ./secrets-crypt.sh encrypt            # -> secrets.tar.enc
#   ./secrets-crypt.sh decrypt            # -> .env, secrets/
#   SECRETS_PASSPHRASE=... ./secrets-crypt.sh encrypt   # non-interactive, for CI
set -euo pipefail

cd "$(dirname "$0")"

ACTION="${1:-}"
BUNDLE="${2:-secrets.tar.enc}"

# Everything that must travel together. Add to this list rather than inventing
# a second bundle — a partial restore is worse than no restore, because it
# looks like it worked.
SOURCES=(".env" "secrets")

usage() {
  echo "usage: $0 encrypt|decrypt [bundle=secrets.tar.enc]" >&2
  exit 2
}

[ "$ACTION" = "encrypt" ] || [ "$ACTION" = "decrypt" ] || usage

read_passphrase() {
  local prompt="$1" value
  read -rs -p "$prompt" value >&2
  echo >&2
  printf '%s' "$value"
}

if [ -z "${SECRETS_PASSPHRASE:-}" ]; then
  SECRETS_PASSPHRASE=$(read_passphrase "Passphrase: ")
  if [ "$ACTION" = "encrypt" ]; then
    confirm=$(read_passphrase "Repeat: ")
    if [ "$SECRETS_PASSPHRASE" != "$confirm" ]; then
      echo "Passphrases do not match." >&2
      exit 1
    fi
  fi
fi
[ -n "$SECRETS_PASSPHRASE" ] || { echo "Empty passphrase." >&2; exit 1; }
export SECRETS_PASSPHRASE

if [ "$ACTION" = "encrypt" ]; then
  present=()
  for src in "${SOURCES[@]}"; do
    [ -e "$src" ] && present+=("$src")
  done
  if [ ${#present[@]} -eq 0 ]; then
    echo "Nothing to encrypt: none of ${SOURCES[*]} exist here." >&2
    exit 1
  fi

  tar -cf - "${present[@]}" \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
        -pass env:SECRETS_PASSPHRASE -out "$BUNDLE"

  echo "Encrypted ${present[*]} -> $BUNDLE"
  echo "Bundle is safe to commit. The sources are not — check .gitignore."
else
  [ -f "$BUNDLE" ] || { echo "No such bundle: $BUNDLE" >&2; exit 1; }

  # Decrypt to a staging directory first. Unpacking straight over .env means a
  # wrong passphrase or a truncated bundle leaves a half-written file where a
  # working one used to be, and the next deploy ships it.
  staging=$(mktemp -d)
  trap 'rm -rf "$staging"' EXIT

  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
        -pass env:SECRETS_PASSPHRASE -in "$BUNDLE" \
        | tar -xf - -C "$staging"; then
    echo "Decryption failed — wrong passphrase, or the bundle is corrupt." >&2
    echo "Nothing on disk was changed." >&2
    exit 1
  fi

  for src in "${SOURCES[@]}"; do
    [ -e "$staging/$src" ] || continue
    if [ -e "$src" ]; then
      backup="${src}.backup-$(date -u +%Y%m%d%H%M%S)"
      cp -a "$src" "$backup"
      echo "Existing $src backed up to $backup"
    fi
    rm -rf "$src"
    cp -a "$staging/$src" "$src"
    echo "Restored $src"
  done

  # Private material should not be group- or world-readable, whatever the
  # umask of whoever ran this.
  [ -f .env ] && chmod 600 .env
  [ -d secrets ] && chmod -R go-rwx secrets
  echo "Done."
fi
