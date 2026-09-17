# Secrets that are neither in git nor on one laptop

Three pieces that together answer "where do the secrets live" for a self-hosted stack:

- **[`secrets-crypt.sh`](secrets-crypt.sh)** — the working set as one encrypted, committable archive
- **[`gitignore.annotated`](gitignore.annotated)** — ignore rules that say why they exist
- **[`VAULT.md`](VAULT.md)** — how services actually receive secrets at deploy time

## The bundle

A stack with twenty services has a `.env` and a `secrets/` directory of certificates and JSON. None of it belongs in git, so it ends up on one engineer's laptop — and onboarding a second person, or rebuilding after a disk failure, becomes an afternoon of asking people for files.

```bash
./secrets-crypt.sh encrypt     # .env + secrets/ -> secrets.tar.enc
./secrets-crypt.sh decrypt     # back again, on any machine with the passphrase
```

AES-256-CBC, PBKDF2 at 600 000 iterations, salted. The ciphertext is committed; the plaintext sources are gitignored. One passphrase, out of band, gets a new machine to a working state.

**This is not a secret manager**, and the distinction matters. It is the bootstrap path and the break-glass path for when Vault is the thing that is down. Runtime delivery is Vault's job.

Two behaviours worth noting because they are the difference between a useful tool and a dangerous one:

- **Decryption stages first.** The archive is unpacked to a temporary directory and only copied over the real files once it opened cleanly. Piping straight over `.env` means a wrong passphrase leaves a half-written file where a working one used to be — and the next deploy ships it.
- **Existing files are backed up before replacement**, and restored files get `chmod 600` regardless of the caller's umask.

```
$ SECRETS_PASSPHRASE=wrong ./secrets-crypt.sh decrypt
Decryption failed — wrong passphrase, or the bundle is corrupt.
Nothing on disk was changed.
```

## The annotated gitignore

Every rule carries its reason. This is not tidiness — it is what makes the file maintainable. A list of bare patterns cannot be edited safely, because the next person cannot tell which lines are load-bearing and which were copied from somewhere in 2019. They either leave dead rules forever or delete a live one.

The rules that earn the most from an explanation are the ones about **per-deployment generated files**:

```gitignore
# Committing one deployment's copy overwrites everyone else's on the next
# pull — and because the file still looks plausible, the breakage surfaces
# later, somewhere else, as a configuration that "was working yesterday".
configs/generated/
**/bootstrap-*.json
```

That rule exists because a stale placeholder file was once committed over a real one, and the failure appeared two environments away from the commit that caused it. Written down, the rule survives the person who learned it.

## Vault layout

[`VAULT.md`](VAULT.md) covers the part that replaced hand-edited env files on production hosts: one mount per environment with identical key paths inside, AppRole for CI rather than a long-lived token, read-only policies for deploy jobs, and secrets pulled at deploy time instead of baked into images.

It also lists what broke while getting there — Vault outages blocking deploys, a key present in one environment and missing in another, and rotations that are not finished until every consumer has restarted.

## Requirements

`bash`, `tar`, `openssl`. Nothing else.
