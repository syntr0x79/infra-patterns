# Three failures wearing one coat

Traffic fronted by a commercial CDN kept breaking. Accounts were suspended, sessions dropped mid-transfer, and throughput degraded. It was treated as one problem, and the work on it was configuration tuning.

It was three independent phenomena, at three different layers, with three different remedies — and the most important one could not be fixed by configuration at all.

## Separating them

**1. Account suspension by the CDN provider, driven by traffic volume.**
Suspensions clustered around a volume threshold (about 500 GB in our case; other operators reported figures up to an order of magnitude higher, which suggests a policy judgement rather than a fixed limit). The decision is made by the provider looking at its own metrics for the resource — traffic shape, ratios, origin behaviour. It has nothing to do with what any network observer sees on the wire.

**2. A client bug dropping sessions on `GOAWAY`.**
The proxy client, at the version in use, terminated an individual session when the CDN sent an HTTP/2 `GOAWAY` during an upload. `GOAWAY` is routine — it is how a server retires a connection gracefully — and the correct response is to open a new connection and continue. This produced random mid-transfer failures, entirely unrelated to the suspensions, and fixable by upgrading.

**3. Detectability of the tunnel by an on-path observer.**
A separate concern at a separate layer: what a middlebox between client and CDN edge can infer. Padding, session-ID handling and multiplexing settings change this. They do not change (1) or (2).

## Why the separation was the deliverable

Before it, weeks had gone into tuning padding and multiplexing parameters — measures that address (3) — against a symptom caused by (1). Those settings could not have worked, and no amount of iterating on them would have produced a result.

**A category error at the start of an investigation cannot be corrected by effort later.** The most valuable output here was a negative one: *stop tuning, this is a business decision by a vendor, and the fix is architectural or commercial.*

## How the primary source was reached

Open sources gave the symptom and folklore. Specialist community discussion gave the volume threshold and confirmed others saw the same pattern. Neither settles anything — both are aggregations of guesses.

The question was closed by the provider's own suspension notice and the specific clause of its terms of service it cited. That turned "we think they ban on volume" into "they ban under this clause, and the clause covers what we are doing".

The general point: **search in passes, escalating specificity.** Open sources for the shape of the problem, specialist communities for practitioner detail, then the primary document — the vendor's notice, the terms, the source code, the RFC. The primary document is what converts a hypothesis into a decision, and it is usually reachable by someone willing to spend an hour more than everyone else did.

## Checklist that came out of it

When one symptom has several plausible causes:

1. **List the layers** the symptom could originate at — vendor policy, application bug, network observer, infrastructure — before proposing any fix.
2. **Ask of each candidate: what would this NOT explain?** The leftovers are usually a second, separate problem.
3. **Check whether the proposed fix operates at the same layer as the cause.** Padding parameters and a vendor's billing policy are not in the same conversation.
4. **Go to the primary document.** A vendor's own notice, the terms, the source, the RFC — community consensus is a lead, not a conclusion.
5. **Write down the separation**, not just the fix. The next person to see the symptom will otherwise merge the three again.
