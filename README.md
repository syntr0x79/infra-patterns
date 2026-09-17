# infra-patterns

Infrastructure patterns from running self-hosted production systems — bare metal, Kubernetes across two datacenters, Patroni, CI that refuses to ship a broken config.

Each directory is a working implementation plus a README that explains the decision behind it, including the trade-offs and the cases where the pattern is the wrong choice. Everything here was rewritten from scratch as a generic, runnable version; none of it is a client's code or configuration.

## Patterns

| | |
|---|---|
| [**ci-config-validation**](ci-config-validation/) | Render HAProxy and nginx templates in CI and check them with the real binaries before deploying. Catches the unsubstituted-variable failure that passes every syntax check and breaks at runtime. Includes a self-test that proves the validator still rejects what it should. |
| [**k8s-cross-dc-zone-affinity**](k8s-cross-dc-zone-affinity/) | Keep the database leader in the same site as the workloads that query it. Anchor pod, `podAffinity`, and a watchdog that switches Patroni over and restarts drifted deployments — with guardrails against promoting a lagging replica and against flapping. 9 tests, no cluster needed. |
| [**agent-command-safety**](agent-command-safety/) | Classify commands an LLM agent proposes as read / mutating / blocked, outside the model. Includes the shell-bypass hole that made it a library — `ssh host "kubectl delete namespace"` had to stop being a read. 63 tests. |
| [**ingress-without-metallb**](ingress-without-metallb/) | Publish ingress with NodePort plus an external HAProxy routing by Host and SNI. Why MetalLB's L2 mode and a VXLAN overlay do not mix, and what replaces it. |
| [**terraform-proxmox-inventory**](terraform-proxmox-inventory/) | One fleet definition creates the VMs and generates the Ansible inventory, so provisioning and configuration cannot drift apart. |
| [**secrets-bundle**](secrets-bundle/) | The encrypted bootstrap bundle, a gitignore where every rule explains itself, and the Vault layout that replaced hand-edited env files. |
| [**warm-standby-rsync**](warm-standby-rsync/) | A standby that is ready in minutes, via a write-only forced-command key. Includes the things that only show up at takeover: locales, unit binding, live SQLite, and why you must not start a singleton service to "test" it. |
| [**research/**](research/) | Three investigations kept for the method: alternating measurement on a drifting channel, a workaround that was causing the incident, and separating three failures that looked like one. |

## Running things

Most patterns verify themselves:

```bash
cd ci-config-validation      && ./scripts/validate.sh && ./scripts/selftest.sh
cd k8s-cross-dc-zone-affinity && ./tests/run.sh
cd agent-command-safety      && PYTHONPATH=src pytest -q
cd ingress-without-metallb   && ./validate.sh
```

Requirements vary by pattern: docker for the config validators, `bash` + `jq` for the watchdog tests, Python 3.10+ for the policy library.

## Related repositories

- [**ai-devops**](https://github.com/syntr0x79/ai-devops) — operations agent with kubectl, helm, Prometheus, Loki and SSH behind a safety layer and an approval flow
- [**ai-codegen**](https://github.com/syntr0x79/ai-codegen) — nine-agent pipeline where stages hand work to each other as artifacts with declared contracts
- [**devopsbot**](https://github.com/syntr0x79/devopsbot) — terminal agent for infrastructure work running against local models through Ollama

## Author

Dmitry Buravtsov — platform and infrastructure engineer. Self-hosted Kubernetes and bare metal, Terraform and Ansible, CI/CD, observability, and the networking underneath it.

## License

MIT — see [LICENSE](LICENSE).
