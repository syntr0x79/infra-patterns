# Why a DNS-based transport failed on mobile networks

A tunnel that encapsulates traffic in DNS queries worked from a wired connection and failed from a mobile one. "Mobile networks block it" was the working theory. It was three separate causes, and only one of them was blocking.

## Setup

- **Server**: a node in a European datacenter, authoritative for a delegated subdomain, listening on UDP/53 only. The transport is a reliable-UDP protocol wrapped in DNS request/response pairs.
- **Client**: a single-board computer with two uplinks — a wired connection through one ISP, and a USB modem on a mobile operator. Switching between them changes exactly one variable.
- **Measurement**: repeated transfers of a fixed payload, throughput and success rate recorded per run.

Having both uplinks on one machine mattered more than anything else in the setup. Comparing a phone on mobile data against a laptop on wired changes the OS, the client build, the DNS resolver and the path at once, and nothing learned that way is attributable.

## The trap in the measurement

First runs looked decisive: wired fast, mobile dead. They were not reproducible.

The channel itself moved — control transfers over the same link, minutes apart, ranged from 6.1 to 29.2 KB/s. A single measurement of configuration A followed by a single measurement of configuration B cannot distinguish a real difference from that drift, and with a five-fold spread it will confidently produce whichever answer the drift happened to favour.

Everything below is from **alternating series**: A, B, A, B, A, five rounds each, compared within the series. Any result that survived only in one direction of the alternation was discarded.

## Cause 1 — MTU, the actual blocker

The documentation recommended an MTU of 900 for TXT-record transport. That value never completed a handshake on mobile.

Tie-break, five alternating rounds each:

| MTU | Success | Throughput |
|-----|---------|-----------|
| 500 | 5/5 | 8.6 KB/s |
| 700 | 5/5 | 6.5 KB/s |
| 900 | 0/5 | — |
| 1200 | 0/5 | — |

The working window was roughly 400–700. The recommended value sat outside it.

The cause is that the operator's recursive resolver sits in the path: the client does not talk to the authoritative server directly, it asks the operator's resolver, which forwards. A response too large for that resolver's own path is dropped, and because the node listens only on UDP — no TCP/53 — there is no fallback to fail over to. The truncation-and-retry mechanism that normally rescues large DNS responses cannot engage.

The lesson generalises past DNS: **a documented default is a measurement someone else took on their path.** When the path includes a middlebox you do not control, the default is a hypothesis.

## Cause 2 — the operator filtering UDP/53 outright

On the mobile uplink, outbound UDP/53 was blocked entirely — not only toward the tunnel's authoritative server, but toward public resolvers and even toward the operator's own resolver addresses. The subscriber session simply does not pass UDP/53 outbound; DNS works because the resolver is reached over the operator's internal path.

This was established by testing three destinations in sequence rather than assuming the block was aimed at the tunnel. It changes the conclusion from "our transport is being blocked" to "this transport cannot exist on this operator without a different port or protocol" — a design constraint rather than a bug to fix.

## Cause 3 — logging destroying a third of the runs

With the log level at `info` plus per-query DNS logging, the node accumulated 285 MB of error log during testing. Disk pressure on the node killed roughly a third of the runs, at random.

This is the one that cost the most time, because its signature is indistinguishable from network flakiness: runs fail intermittently, on no pattern, and every failure looks like the thing you are already investigating. It was only isolated by noticing that failures correlated with test *duration* rather than with configuration.

**A test rig with debug logging enabled is a test rig that reports its own noise as data.**

## Result

MTU 500, log level `warning`, per-query logging off. Success 5/5 on mobile at 8.6 KB/s, stable across repeated series. Committed to configuration management with a backup of the previous live config alongside it.

Record types, tested separately: TXT worked on every path; AAAA only at MTU ≤ 300; A never — the record is too small to carry the protocol's framing. An alternative port was not available: the node's provider permits only UDP/53 inbound.

## What to take from it

1. **Alternate, do not sequence.** If the channel drifts more than the effect, sequential A-then-B measurement produces noise with a confident narrative attached.
2. **Test each hop, not the end-to-end path.** "Mobile blocks it" was three findings wearing one coat, with different remedies at different layers.
3. **Turn off debug logging before measuring**, or spend a day chasing the rig.
4. **A negative result is a result.** "This cannot work on this operator at this port" closed a line of work that would otherwise have absorbed weeks of configuration tuning.
