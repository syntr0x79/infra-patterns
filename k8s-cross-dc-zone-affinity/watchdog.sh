#!/usr/bin/env sh
# Zone watchdog.
#
# Keeps the PostgreSQL leader in the same failure domain as the workloads that
# talk to it. Runs on a schedule; does nothing at all on a healthy cluster.
#
# The loop:
#   1. find the anchor pod, read the zone of the node it runs on
#   2. ask Patroni which member is leader, map it to a zone
#   3. if the zones differ, switch the leader over to the anchor's zone
#   4. restart any pinned deployment whose pods drifted out of the zone
#
# Guardrails, in the order they matter:
#   - never switch over unless every member is running and replication lag is
#     under MAX_LAG_BYTES — a switchover into a lagging replica trades latency
#     for data loss, which is not a trade this script is allowed to make
#   - never switch over twice inside COOLDOWN_SECONDS, so a flapping anchor
#     cannot turn into a flapping database
#   - DRY_RUN=true prints decisions and changes nothing
set -eu

NAMESPACE="${NAMESPACE:?}"                 # namespace of the anchor workload
ANCHOR_LABEL="${ANCHOR_LABEL:?}"           # e.g. app=rabbitmq
PATRONI_MEMBERS="${PATRONI_MEMBERS:?}"     # name=url,name=url
MEMBER_ZONES="${MEMBER_ZONES:?}"           # name=zone,name=zone
PINNED_DEPLOYMENTS="${PINNED_DEPLOYMENTS:-}" # ns/name,ns/name — optional
ZONE_LABEL="${ZONE_LABEL:-topology.kubernetes.io/zone}"
MAX_LAG_BYTES="${MAX_LAG_BYTES:-10485760}" # 10 MiB
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-1800}"
STATE_CONFIGMAP="${STATE_CONFIGMAP:-zone-watchdog-state}"
DRY_RUN="${DRY_RUN:-false}"

log() { echo "$(date -u +%FT%TZ) $*"; }

# Label keys contain dots, which jsonpath treats as path separators. Asking for
# JSON and indexing with jq avoids the escaping entirely.
node_zone() {
  kubectl get node "$1" -o json | jq -r --arg l "$ZONE_LABEL" '.metadata.labels[$l] // ""'
}

lookup() {  # lookup "a=1,b=2" a  ->  1
  echo "$1" | tr ',' '\n' | while IFS='=' read -r k v; do
    [ "$k" = "$2" ] && { echo "$v"; break; }
  done
}

# ---------------------------------------------------------------- anchor zone

anchor_pod=$(kubectl get pods -n "$NAMESPACE" -l "$ANCHOR_LABEL" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$anchor_pod" ]; then
  log "anchor pod not found (ns=$NAMESPACE label=$ANCHOR_LABEL) — nothing to compare against, exiting"
  exit 0
fi

anchor_node=$(kubectl get pod -n "$NAMESPACE" "$anchor_pod" -o jsonpath='{.spec.nodeName}')
anchor_zone=$(node_zone "$anchor_node")

if [ -z "$anchor_zone" ]; then
  log "node $anchor_node has no $ZONE_LABEL label — cannot determine zone, exiting"
  exit 0
fi
log "anchor: pod=$anchor_pod node=$anchor_node zone=$anchor_zone"

# ------------------------------------------------------------- cluster state

cluster=""
for pair in $(echo "$PATRONI_MEMBERS" | tr ',' ' '); do
  url=${pair#*=}
  if cluster=$(curl -sf -m 5 "$url/cluster"); then
    break
  fi
  cluster=""
done

if [ -z "$cluster" ]; then
  log "ERROR: no Patroni member answered /cluster"
  exit 1
fi

leader=$(echo "$cluster" | jq -r '.members[] | select(.role=="leader") | .name')
if [ -z "$leader" ] || [ "$leader" = "null" ]; then
  log "no leader in cluster right now — Patroni is mid-election, leaving it alone"
  exit 0
fi

leader_zone=$(lookup "$MEMBER_ZONES" "$leader")
log "patroni: leader=$leader zone=${leader_zone:-unknown}"

if [ "$leader_zone" = "$anchor_zone" ]; then
  log "leader already in the anchor zone — nothing to do"
else
  # ------------------------------------------------------------- switchover

  candidate=""
  for pair in $(echo "$MEMBER_ZONES" | tr ',' ' '); do
    name=${pair%%=*}; zone=${pair#*=}
    if [ "$zone" = "$anchor_zone" ] && [ "$name" != "$leader" ]; then
      candidate="$name"
    fi
  done

  if [ -z "$candidate" ]; then
    log "no member in zone $anchor_zone to promote — leaving the leader where it is"
  else
    unhealthy=$(echo "$cluster" | jq -r '[.members[] | select(.state!="running" and .state!="streaming")] | length')
    maxlag=$(echo "$cluster" | jq -r '[.members[] | select(.role!="leader") | (.lag // 0)] | max // 0')

    if [ "$unhealthy" != "0" ]; then
      log "REFUSING switchover: $unhealthy member(s) not running/streaming"
    elif [ "$maxlag" -gt "$MAX_LAG_BYTES" ]; then
      log "REFUSING switchover: replication lag ${maxlag}B exceeds ${MAX_LAG_BYTES}B"
    else
      last=$(kubectl get configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" \
             -o jsonpath='{.data.last_switchover_epoch}' 2>/dev/null || echo 0)
      now=$(date -u +%s)
      since=$(( now - ${last:-0} ))

      if [ "$since" -lt "$COOLDOWN_SECONDS" ]; then
        log "REFUSING switchover: last one was ${since}s ago, cooldown is ${COOLDOWN_SECONDS}s"
      else
        leader_url=$(lookup "$PATRONI_MEMBERS" "$leader")
        log "switching over: $leader ($leader_zone) -> $candidate ($anchor_zone)"
        if [ "$DRY_RUN" = "true" ]; then
          log "DRY_RUN: POST $leader_url/switchover leader=$leader candidate=$candidate"
        else
          if curl -sf -m 30 -XPOST "$leader_url/switchover" \
               -H 'Content-Type: application/json' \
               -d "{\"leader\":\"$leader\",\"candidate\":\"$candidate\"}"; then
            kubectl create configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" \
              --from-literal=last_switchover_epoch="$now" \
              --dry-run=client -o yaml | kubectl apply -f - >/dev/null
            log "switchover accepted"
          else
            log "ERROR: switchover request failed"
            exit 1
          fi
        fi
      fi
    fi
  fi
fi

# --------------------------------------------------------- drifted workloads

# podAffinity only applies at scheduling time. A pod that was already running
# when the anchor moved stays where it is — correctly scheduled yesterday,
# in the wrong zone today. Restarting it makes the scheduler re-evaluate.
[ -n "$PINNED_DEPLOYMENTS" ] || { log "done"; exit 0; }

for ref in $(echo "$PINNED_DEPLOYMENTS" | tr ',' ' '); do
  ns=${ref%%/*}; name=${ref#*/}

  selector=$(kubectl get deployment "$name" -n "$ns" -o json 2>/dev/null \
    | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
  if [ -z "$selector" ] || [ "$selector" = "null" ]; then
    log "deployment $ref not found, skipping"
    continue
  fi

  drifted=0
  for node in $(kubectl get pods -n "$ns" -l "$selector" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].spec.nodeName}'); do
    [ "$(node_zone "$node")" = "$anchor_zone" ] || drifted=1
  done

  if [ "$drifted" = "1" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      log "DRY_RUN: would restart $ref (pods outside $anchor_zone)"
    else
      log "restarting $ref — pods outside $anchor_zone"
      kubectl rollout restart deployment "$name" -n "$ns"
    fi
  else
    log "$ref aligned"
  fi
done

log "done"
