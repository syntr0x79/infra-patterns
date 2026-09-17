# Keeping a cross-datacenter cluster fast

A Kubernetes cluster spread across two sites survives losing one. It also pays a latency tax on every request that crosses the link — and the worst version of that tax is invisible: the database leader sits in site A, the services that query it run in site B, and every query pays the round trip. Nothing is down. Nothing alerts. Everything is just slower than it should be, and nobody can say when it started.

This is the fix: pin the latency-sensitive workloads to one anchor, and keep the database leader in the anchor's zone with a watchdog.

```
site-a                          site-b
┌────────────────────┐          ┌────────────────────┐
│ workers 1-8        │          │ workers 9-16       │
│                    │          │  ┌──────────────┐  │
│                    │          │  │ queue (anchor)│ │
│                    │          │  │ api ─────────┐│ │
│                    │          │  │ worker       ││ │
│                    │          │  │ pgbouncer ───┼┼─┼──┐
└────────────────────┘          └──┴──────────────┴┴─┘  │
                                                         │
  db-1 (replica)   ←── streaming replication ──   db-2 (leader) ←┘
```

The watchdog's entire job is keeping that last arrow short.

## How it works

1. Find the anchor pod; read the `topology.kubernetes.io/zone` label of its node.
2. Ask Patroni which member is leader; map it to a zone.
3. If the zones differ — switch the leader over to a member in the anchor's zone.
4. Restart any pinned deployment whose pods drifted out of the zone.

Step 4 exists because **`podAffinity` only applies at scheduling time**. A pod scheduled correctly yesterday, next to an anchor that has since moved, stays exactly where it is — `IgnoredDuringExecution` is not a footnote, it is the whole behaviour. Without a restart, affinity rules silently stop describing reality.

## The guardrails are the interesting part

A script that can promote a database in production is a script that needs to be hard to misuse. In order of importance:

**It refuses to switch over into a lagging replica.** If any member is behind by more than `MAX_LAG_BYTES`, or any member is not `running`/`streaming`, the run stops and logs why. The alternative — promoting a replica that is behind — trades latency for data loss, and that is not a trade a cron job gets to make on its own.

**It refuses to switch over twice inside a cooldown.** The anchor restarting during a deploy is an ordinary event, and without a cooldown an ordinary event becomes a database failover, twice. The last switchover timestamp lives in a ConfigMap, so the cooldown survives pod restarts.

**It does nothing when there is no leader.** A cluster mid-election is a cluster Patroni is already fixing. Interfering makes it worse.

**It exits rather than guesses.** No anchor pod, no zone label on the node, no member in the target zone — each of these ends the run quietly. The failure mode of this script is "does nothing", never "does something creative".

**RBAC is narrow by construction.** Read pods, nodes and deployments; patch deployments; write one ConfigMap in one namespace. It cannot delete anything and cannot read secrets, so a bug in the shell script cannot become an incident.

`DRY_RUN=true` prints every decision and changes nothing — worth running for a week before letting it act.

## Tests

The script's job is deciding whether to touch production, so the decisions are what is tested. `kubectl` and `curl` are replaced by stubs serving fixture JSON:

```
$ ./tests/run.sh
zone watchdog
  ok   aligned cluster is left alone
  ok   aligned cluster made no switchover call
  ok   misaligned cluster switches over
  ok   switchover is accepted
  ok   lagging replica blocks switchover
  ok   unhealthy member blocks switchover
  ok   election in progress is left alone
  ok   missing anchor exits cleanly
  ok   drifted deployment is restarted

passed: 9, failed: 0
```

No cluster required — `bash`, `jq` and a few fixtures.

## Installing

```bash
kubectl create configmap zone-watchdog-script -n prod --from-file=watchdog.sh
kubectl apply -f watchdog.yaml
kubectl apply -f affinity.yaml     # anchor + the deployments that follow it

# Nodes need the zone label; most bare-metal installers do not set it.
kubectl label node worker-1 topology.kubernetes.io/zone=site-a
kubectl label node worker-9 topology.kubernetes.io/zone=site-b
```

Configuration is the `zone-watchdog-config` ConfigMap: anchor label, Patroni member URLs, member→zone mapping, the deployments to keep aligned, lag threshold, cooldown.

## When you do not need this

If both sites are in the same metro with sub-millisecond RTT, the tax is too small to engineer around. If your database is a managed service with its own multi-region story, use that instead. This pattern is for self-hosted Patroni on your own hardware in two real datacenters — where the link is tens of milliseconds and nobody else is going to keep the leader in the right place for you.

## Related

`podAffinity` with `required...`, not `preferred...`. A preferred rule degrades silently into exactly the cross-site latency the pattern exists to prevent, and nothing tells you it happened. See the comments in [`affinity.yaml`](affinity.yaml).
