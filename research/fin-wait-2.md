# Half-closed sockets on edge nodes

Edge proxy nodes accumulated sockets in `FIN-WAIT-2` until inbound listeners stopped accepting traffic. The standing workaround was a cron job restarting the container through the control panel's API. After a restart some listeners came back and some did not, so the restart was often run twice.

The team's explanation was a memory leak in the proxy.

## The observation that broke the theory

A leak explains memory growth. It does not explain **why connections to neighbouring nodes drop at the moment of restart** — and that was the part operators actually complained about.

That question reframed the problem. The restart was not a cure with a side effect; the restart *was* the damage, and it was being applied on a schedule for a reason nobody had verified.

## Establishing a baseline first

Before changing anything, sampling every 5 minutes for 30 minutes on two nodes, one healthy and one complaining:

```
t+0    node-a: 1083   node-b: 532
t+5    node-a:  942   node-b: 591
t+25   node-a: 1049   node-b: 572
t+30   node-a:  1002   node-b: 588
```

Two things fell out immediately. The counts **oscillate rather than climb** — which is not the shape of a leak. And the "healthy" node carried about twice the half-closed sockets of the "broken" one, so the metric being used to identify the sick node did not correlate with the symptom at all.

Without this baseline, any subsequent change would have been evaluated against a number that moves ±15% on its own. Most "the fix worked" conclusions in this class of problem are that noise.

## Reading the source

`FIN-WAIT-2` means the local side sent FIN and is waiting for the peer's FIN. Sockets stuck there are a peer that never closes, or a local close path that returns before the teardown completes.

Reading the proxy's connection-closing path showed the second: a close that returns without waiting for the transport-level handshake, leaving the kernel socket half-closed until it times out. The upstream project had an open issue describing the same behaviour — found after knowing what to search for, which is the usual order.

So the sockets were a symptom of ordinary connection churn plus a slow teardown path, not of a leak, and not of anything the node was doing wrong.

## Why the restart hurt

Restarting the container tears down every established connection, including long-lived ones to neighbouring nodes that carry relayed traffic. Those take time to re-establish, and some inbound listeners lost their configuration binding in the process — which is why a second restart "helped": it re-ran the initialisation that the first one had interrupted.

The workaround was generating the incident it was deployed to prevent.

## What changed

- The blanket cron restart was replaced with a targeted script acting on the specific condition, leaving healthy connections alone.
- Effect confirmed by repeating the same 5-minute sampling over 30-minute windows, before and after, on both nodes — not by a single reading.
- The socket count was retired as a health signal, since it did not track the symptom.

## What to take from it

1. **Ask what the theory does not explain.** "Memory leak" covered the growth and nothing else. The unexplained detail — neighbours dropping — was where the answer was.
2. **Baseline before fixing.** A metric that swings 15% on its own will confirm any change you want it to confirm.
3. **A workaround that has been running for months is part of the system** and belongs in the suspect list, not the background.
4. **Read the source of the thing you run.** Twenty minutes in the proxy's close path settled a question that months of operational folklore had not.
