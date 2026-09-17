# Publishing ingress without MetalLB

On bare metal there is no cloud load balancer, so `type: LoadBalancer` does nothing and the usual answer is MetalLB. This is the other answer: a fixed NodePort on every worker, and an external HAProxy that health-checks them and routes by `Host` on port 80 and by TLS SNI on port 443.

```
            ┌─────────────────────────────────────────┐
client ───▶ │ HAProxy (edge)                          │
            │  :80   route by Host header             │
            │  :443  route by SNI, no TLS termination │
            └───────────────┬─────────────────────────┘
                            │ health check GET /healthz
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
  worker-1:32080      worker-2:32080      worker-3:32080
        └────────── ingress controller ─────────┘
```

## Why not MetalLB

MetalLB in L2 mode works by answering ARP for the service address: one node claims the IP, and on failure another node takes over by broadcasting a gratuitous ARP. That is fine on a normal switched LAN.

It stops being fine when the cluster spans an overlay. With workers on both sides of a VXLAN link, every ARP broadcast is replicated across the tunnel to every participating node. Under load — and especially with several service IPs failing over at once — the broadcast domain saturates and takes the overlay with it. The failure looks like a network problem, not a load-balancer problem, which is what makes it expensive to diagnose.

BGP mode avoids this, but it needs routers you control and are allowed to peer with. In a rented rack, or with a provider that will not peer, that option does not exist.

Removing layer 2 from the path removes the entire class of problem. Nothing announces anything; HAProxy simply stops sending traffic to a backend that fails its check.

## Design decisions

**SNI routing without TLS termination.** Port 443 runs in TCP mode: HAProxy reads the SNI from the ClientHello and passes the connection through untouched. Certificates stay in the cluster, where cert-manager already renews them. Terminating at the edge would mean shipping certificates out to the load balancer and building a second renewal path for no benefit.

This requires `tcp-request inspect-delay` and an `accept if { req_ssl_hello_type 1 }` — without them the ACL is evaluated before the handshake arrives and everything lands on the default backend. That failure is intermittent under load and looks like a routing bug.

**Health checks hit `/healthz`, not the TCP port.** A node whose ingress controller is up but not ready will happily accept a TCP connection and then fail the request. Checking HTTP means "ready to serve", which is the actual question. The HTTPS backend checks the *HTTP* NodePort for the same reason — a TLS handshake against a pass-through port tells you nothing useful.

**`externalTrafficPolicy: Cluster`, and the client IP comes from `X-Forwarded-For`.** `Local` preserves the source address but concentrates traffic on whichever nodes run a controller pod and makes every other node fail its check. With `Cluster`, any node is a valid entry point, and the real client IP is recovered from the header HAProxy sets. The trade is only sound because the edge is trusted to set it — hence `proxy-real-ip-cidr` pinned to the edge address, so a client cannot forge its own.

**NodePorts are pinned, not allocated.** The edge config references `32080`/`32443` by number. A port that changes on redeploy is an outage nobody attributes to the right change.

## Failover behaviour

`inter 1s fall 2` — a dead worker leaves rotation in about two seconds, with no ARP, no convergence and no shared state between the edge and the cluster. Adding a worker means adding one line to `k8s_workers`; nothing in the cluster needs to know the edge exists.

The `ingress_sites` list allows a domain to be served by a *different* set of workers — a second cluster, a canary, a zone-pinned workload — behind the same public address. That is awkward with MetalLB and free here.

## Files

```
k8s/ingress-nodeport.yaml   NodePort service + controller ConfigMap
haproxy/haproxy.cfg.j2      edge template (Jinja2 — Ansible, or anything)
haproxy/vars.example.yml    workers, ports, sites
validate.sh                 render the template, run haproxy -c on the result
```

```
$ ./validate.sh
haproxy.cfg.j2 renders to a valid configuration
```

Needs docker and a Python with jinja2 and pyyaml — any Ansible install has both: `PYTHON=$(which python3) ./validate.sh`.

## When MetalLB is the better answer

A single-site cluster on a plain L2 network, or a network where you can run BGP. Then MetalLB gives you real service IPs and one less machine to own. This pattern is for the case where layer 2 is not trustworthy — an overlay, a rented rack, a provider that will not peer — and for the case where you want the edge to do host- and SNI-level routing that a service IP cannot express.
