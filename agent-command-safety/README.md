# cmdpolicy

Decide whether a command an LLM agent proposed is allowed to run — outside the model, as a pure function over a policy that is data.

```python
from cmdpolicy import classify

classify("kubectl", "get pods -n prod").verdict        # Verdict.READ
classify("kubectl", "scale deploy/api --replicas=0")   # Verdict.MUTATING
classify("kubectl", "delete namespace prod").verdict   # Verdict.BLOCKED
classify("kubectl", "get secret db -n prod").reason    # 'secrets are never read through the agent'
```

Three verdicts: **READ** runs, **MUTATING** runs after a human approves, **BLOCKED** never runs and has no approval path.

## Why not just tell the model

A system prompt asking a model not to delete things is a request, not a boundary. It weakens as context grows, it can be argued with by anything the model reads — including output from a host that is already compromised — and it silently regresses when you upgrade the model. None of that applies to a parser that returns an enum.

The split also makes the interesting question answerable: *what is this agent allowed to do?* With prompt-based restraint the answer is "read 900 lines of instructions and hope". Here it is one file, and it is testable.

## Three decisions worth arguing about

**BLOCKED exists, separately from "needs approval".** An approval dialog for `delete namespace prod` is not a control. Under incident pressure people approve what they are shown — the confirmation becomes a reflex, and the more it appears the less it means. A hard block means the question is never asked.

**Secrets are blocked, not redacted.** `kubectl get secret` and `describe secret` never execute. Redacting the output afterwards is too late: the value was already in the model's context, and from there in the transcript, the logs, and anywhere the transcript goes.

**Shell defaults to permissive; kubectl defaults to restrictive.** This inversion is deliberate. An allowlist of safe shell commands is either useless or endless, so for shell the policy enumerates what must never happen and what needs a human, and lets everything else through. `kubectl` has a finite verb set, so there the unknown case fails closed — an unrecognised subcommand is blocked, which keeps the policy from quietly weakening as new verbs appear upstream.

## The bypass that made this a library

The first version classified `ssh` through the shell rules and `kubectl` through the kubectl rules, which looks obviously right and is obviously wrong:

```
ssh host "kubectl delete namespace prod"   →   READ
```

The shell policy knows nothing about kubectl. Every rule in the kubectl policy was one `ssh` away from being decorative. A boundary has to hold whichever door the agent walks through, so a shell command that invokes a known tool is now delegated to that tool's rules — and there are tests pinning it:

```python
classify("ssh", "kubectl delete namespace prod").verdict   # Verdict.BLOCKED
classify("bash", "cd /tmp && kubectl get secret x").verdict  # Verdict.BLOCKED
```

Chained commands take the worst verdict of their parts, for the same reason: `uptime && rm -rf /` is not a read.

## Policy as data

```python
from cmdpolicy import classify, default_policy

policy = default_policy().with_blocked(r"\bvault\s+kv\s+get\b", "secret read")
classify("ssh", "vault kv get secret/db", policy).verdict   # Verdict.BLOCKED
```

`Policy` is a frozen dataclass and `with_blocked` returns a new one, so a caller can extend the defaults but cannot weaken them in place — a rule you rely on cannot be removed by code running later in the same process.

## Tests

```
$ PYTHONPATH=src pytest -q
63 passed
```

Two of them are there because the tests found real bugs during development: `--context prod get pods` was classified as an unknown command (flag *values* were being read as the subcommand), and the `ssh`-bypass above. Both are pinned now.

## Install

```bash
pip install -e .
```

No dependencies. Python 3.10+.

## Where it came from

Extracted and generalised from the safety layer of an operations agent that has kubectl, helm and SSH against production — see [ai-devops](https://github.com/syntr0x79/ai-devops), where the same idea is wired into an approval flow and an append-only audit log.
