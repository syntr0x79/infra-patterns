#!/usr/bin/env bash
# Push application state from the primary to the standby.
#
# Not a backup and not replication: this keeps a second machine ready to take
# over in minutes instead of hours. Code, virtualenvs, host-local config and
# runtime state go across; nothing is started on the other side.
#
# Runs on the PRIMARY, pushing outward. The standby holds a key restricted to
# a forced rrsync command, so a compromised primary can write into one
# directory on the standby and do nothing else. Pulling instead would require
# the standby to hold a key that can read everything on production — the wrong
# direction for the blast radius.
set -euo pipefail

STANDBY_HOST="${STANDBY_HOST:?set STANDBY_HOST}"
STANDBY_USER="${STANDBY_USER:-standby}"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_warm_sync}"
SYNC_ROOT="${SYNC_ROOT:-/opt}"
SERVICES="${SERVICES:?comma-separated list of directories under $SYNC_ROOT}"
SQLITE_FILES="${SQLITE_FILES:-}"   # comma-separated absolute paths, optional
LOCK_FILE="${LOCK_FILE:-/var/lock/warm-sync.lock}"

log() { echo "$(date -u +%FT%TZ) $*"; }

# Overlapping runs would have two rsyncs writing the same tree. The timer
# fires hourly and a full sync can exceed an hour after a big deploy.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another sync is running, skipping this tick"
  exit 0
fi

ssh_opts=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# --- SQLite needs a snapshot, not a file copy -------------------------------
# A live SQLite database in WAL mode is three files that must agree. rsync
# copies them one at a time, so the standby can receive a torn set that looks
# fine until it is opened. The backup API takes a consistent snapshot while
# the database stays in use.
staged_sqlite=()
if [ -n "$SQLITE_FILES" ]; then
  snapshot_dir=$(mktemp -d)
  trap 'rm -rf "$snapshot_dir"' EXIT
  IFS=',' read -ra dbs <<< "$SQLITE_FILES"
  for db in "${dbs[@]}"; do
    [ -f "$db" ] || { log "sqlite: $db missing, skipping"; continue; }
    out="$snapshot_dir/$(echo "$db" | tr '/' '_')"
    python3 - "$db" "$out" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
with sqlite3.connect(f"file:{src}?mode=ro", uri=True) as s, sqlite3.connect(dst) as d:
    s.backup(d)
PY
    staged_sqlite+=("$db|$out")
    log "sqlite: snapshot of $db"
  done
fi

# --- code, venvs, host-local config ----------------------------------------
IFS=',' read -ra services <<< "$SERVICES"
for svc in "${services[@]}"; do
  src="$SYNC_ROOT/$svc"
  [ -d "$src" ] || { log "$svc: no such directory, skipping"; continue; }

  log "$svc: syncing"
  rsync -aHAX --delete --numeric-ids \
    --exclude='*.pyc' --exclude='__pycache__/' \
    --exclude='.git/' --exclude='*.log' \
    --exclude='node_modules/.cache/' \
    -e "ssh ${ssh_opts[*]}" \
    "$src/" "$STANDBY_USER@$STANDBY_HOST:$SYNC_ROOT/$svc/"
done

# --- consistent SQLite snapshots last --------------------------------------
for entry in "${staged_sqlite[@]:-}"; do
  [ -n "$entry" ] || continue
  db="${entry%%|*}"; snap="${entry##*|}"
  rsync -a -e "ssh ${ssh_opts[*]}" \
    "$snap" "$STANDBY_USER@$STANDBY_HOST:$db"
  log "sqlite: shipped $db"
done

log "sync complete"
