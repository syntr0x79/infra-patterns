# Warm standby with rsync

A second machine that already has the code, the virtualenvs and the runtime state, so a takeover is "start the units" rather than "rebuild the host". Deliberately boring: rsync, a forced-command SSH key and a systemd timer.

```
primary ──rsync (push, write-only key)──▶ standby
   │                                         │
   └── services running                      └── same files, nothing started
```

## Why push, and why write-only

The sync runs on the primary and pushes outward. The standby holds a key restricted to `rrsync -wo /opt`:

```
command="/usr/bin/rrsync -wo /opt",restrict ssh-ed25519 AAAA... warm-sync@primary
```

That key cannot get a shell, cannot forward ports, cannot read data back out, and cannot touch anything outside `/opt`. A compromised primary can corrupt one directory on the standby and nothing else.

Pulling would invert this: the standby would need a key that can *read everything* on production. For a machine whose entire job is sitting idle, that is the wrong direction for the blast radius.

## Why not just rebuild from CI

Because "rebuild from CI" is a claim about a path nobody walks. The standby that is rebuilt from scratch during an incident is the standby that discovers a missing system package, an unavailable mirror, or a pinned dependency that no longer resolves — at the worst possible time. A warm copy is a claim you can test on a Tuesday.

It does not replace backups. Deletions replicate; `--delete` is on, because a standby that accumulates files the primary removed drifts into something nobody has tested.

## What this cost us to learn

**Virtualenvs copy byte-for-byte only when the two machines match.** Same OS, same architecture, same interpreter patch version. When they match, copying the venv is enormously faster than rebuilding it and removes any chance of resolving a different dependency set on the standby. When they do not, the copy produces a venv that imports fine and fails on the first compiled extension. Verify the pair before relying on it; treat the interpreter as part of the contract, not an implementation detail.

**Live SQLite in WAL mode is three files that must agree.** rsync copies them one at a time, so the standby can receive a torn set that opens cleanly and is subtly wrong. The script takes a snapshot through SQLite's backup API instead, while the database stays in use.

**Unit files must not be synced.** They contain host-local facts — the address to bind, the interface, sometimes the node name. Copying the primary's units gives the standby a service that binds an address it does not have. Install them separately, leave them `disabled`, and let the takeover procedure enable them.

**OS-level state is not in the sync, and you will forget that.** Locales, system packages, users, `/etc`. A service that calls `setlocale` at import time crashes on a standby without that locale generated — a failure that appears only at takeover, which is precisely when nobody wants a new variable. Bootstrap the standby once, deliberately, and write down what that involved.

**Do not start a singleton on the standby to "test" it.** Anything holding an exclusive external resource — a long-polling bot connection, a queue consumer with a fixed name, a leader lease — will fight the primary the moment it starts. In one measured case the conflict began 37 ms after start, and the primary's process did not die or restart: it logged an error inside its own loop and recovered eleven seconds later. Restart counters showed nothing on either side. Verify a standby by checking files, not by starting services, and if you must start one, do it on a spare environment.

## Layout

```
scripts/warm-sync.sh              runs on the primary, pushes outward
systemd/warm-sync.service         oneshot, nice'd, IO class idle
systemd/warm-sync.timer           hourly, randomised delay, Persistent=true
standby-authorized_keys.example   the forced-command key
warm-sync.env.example             what to sync and where
```

Install:

```bash
# primary
install -m 755 scripts/warm-sync.sh /usr/local/bin/warm-sync.sh
install -m 600 warm-sync.env.example /etc/warm-sync.env   # then edit
systemctl enable --now warm-sync.timer

# standby: create the user, add the restricted key, create /opt
```

The timer is `Persistent=true`, so a primary that was down catches up on boot instead of waiting for the next hour. `flock` in the script means a sync that outruns its interval skips the next tick rather than running twice over the same tree.

## When a CI step is better than the timer

If deploys are frequent, syncing right after a successful deploy keeps the standby fresher than an hourly timer. Keep the timer anyway: it is the safety net for services that have no pipeline, which in any long-lived stack is always more of them than you expect.
