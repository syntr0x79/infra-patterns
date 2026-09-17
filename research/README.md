# Investigations

Three write-ups from production work, kept for the method rather than the conclusions. Each one is a case where the obvious explanation was wrong and the way out was measurement rather than more configuration.

| | |
|---|---|
| [**Why a DNS-based transport failed on mobile networks**](dns-tunnel-mtu.md) | Three independent causes behind one symptom. MTU tie-break on a channel that drifted five-fold between runs, an operator blocking a protocol outright, and a test rig that was corrupting its own results. |
| [**Half-closed sockets on edge nodes**](fin-wait-2.md) | A months-old workaround turned out to be causing the incident it was deployed to prevent. Baseline sampling and twenty minutes in the upstream source settled it. |
| [**Three failures wearing one coat**](cdn-ban-triage.md) | Separating a vendor policy decision, a client bug and a detectability concern that had been treated as one problem — and why the most valuable finding was that configuration could not fix it. |

All specifics — hosts, domains, providers, identifiers — are removed. What is left is the reasoning, which is the part worth keeping.

## The recurring lessons

**Alternate, do not sequence.** When the channel drifts more than the effect you are measuring, A-then-B produces noise with a confident story attached. A, B, A, B, A.

**Baseline before changing anything.** A metric that swings 15% on its own will confirm whatever you hoped.

**Ask what your theory does not explain.** The leftover detail is usually where the real cause is, or where the second problem is hiding.

**Check that the fix is at the same layer as the cause.** Tuning transport parameters against a vendor's billing policy cannot work, however carefully it is done.

**Reach the primary document.** Community consensus is a lead. The vendor's notice, the terms of service, the source code, the RFC — that is what turns a hypothesis into a decision.

**A negative result is a result.** "This cannot work here, stop" is often the most expensive finding to produce and the most valuable to deliver.
