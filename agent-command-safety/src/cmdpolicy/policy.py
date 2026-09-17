"""Command classification for agents that can reach production.

Three verdicts, and the ordering between them is the design:

    BLOCKED   never runs, no approval path exists
    MUTATING  runs only after a human approves it
    READ      runs

`BLOCKED` is checked first and wins over everything. An approval prompt for
`delete namespace` is not a safety control — under time pressure a human
approves what they are shown, and the whole value of a hard block is that the
question is never asked.

Why this lives outside the model: a system prompt asking a model not to delete
things is a request, not a boundary. It degrades with context length, it can be
argued with by anything the model reads — including tool output from a
compromised host — and it silently regresses when the model is upgraded. A
parser that returns an enum does none of those.
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass, field, replace
from enum import Enum


class Verdict(str, Enum):
    READ = "read"
    MUTATING = "mutating"
    BLOCKED = "blocked"


@dataclass(frozen=True)
class Decision:
    verdict: Verdict
    reason: str
    tool: str
    command: str

    @property
    def allowed_without_approval(self) -> bool:
        return self.verdict is Verdict.READ


@dataclass(frozen=True)
class Policy:
    """Everything the classifier knows, as data.

    Subcommand sets are matched against the first tokens of the command, so
    both "delete" and "delete namespace" work as entries; the most specific
    match wins.
    """

    kubectl_read: frozenset[str] = frozenset({
        "get", "describe", "logs", "top", "explain", "events", "api-resources",
        "api-versions", "cluster-info", "config", "auth", "version", "diff",
    })
    kubectl_mutating: frozenset[str] = frozenset({
        "scale", "delete", "cordon", "uncordon", "drain", "label", "annotate",
        "patch", "edit", "apply", "create", "replace", "taint", "set",
        "rollout restart", "rollout undo", "rollout pause", "rollout resume",
    })
    kubectl_blocked: frozenset[str] = frozenset({
        "delete namespace", "delete pvc", "delete pv", "delete node",
        "get secret", "describe secret", "exec", "attach", "cp", "proxy",
        "port-forward",
    })
    kubectl_read_overrides: frozenset[str] = frozenset({
        "rollout status", "rollout history",
    })

    helm_read: frozenset[str] = frozenset({
        "list", "status", "history", "get", "show", "search", "repo", "version",
        "template", "diff",
    })
    helm_mutating: frozenset[str] = frozenset({"upgrade", "install", "rollback"})
    helm_blocked: frozenset[str] = frozenset({"uninstall", "delete"})

    # Shell is unbounded, so the shape of the policy inverts: permissive by
    # default, with an explicit list of what must never happen and an explicit
    # list of what needs a human. An allowlist for shell is either useless or
    # endless.
    shell_blocked: tuple[tuple[str, str], ...] = (
        (r"\brm\s+(-[a-zA-Z]*\s+)*-?[rRf]{1,2}[a-zA-Z]*\s+/\s*($|\s)", "recursive delete of /"),
        (r"\bmkfs(\.\w+)?\b", "filesystem creation"),
        (r"\bdd\s+.*\bof=/dev/(sd|nvme|vd|hd)", "raw write to a block device"),
        (r">\s*/dev/(sd|nvme|vd|hd)", "raw write to a block device"),
        (r":\(\)\s*\{.*\}\s*;?\s*:", "fork bomb"),
        (r"\b(shutdown|reboot|poweroff|halt)\b", "host shutdown or reboot"),
        (r"\binit\s+[06]\b", "host shutdown or reboot"),
        (r"\bchmod\s+(-R\s+)?777\s+/(\s|$)", "world-writable root"),
        (r"\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(ba|z|k|)sh\b", "piping a download into a shell"),
        (r"/etc/(shadow|gshadow|sudoers)\b", "credential or sudo policy file"),
        (r"\bhistory\s+-c\b", "clearing shell history"),
        (r"\bgpasswd\b|\busermod\s+.*-aG\s+(sudo|wheel|docker)", "privilege grant"),
        (r"\biptables\s+-F\b|\bufw\s+disable\b", "flushing the firewall"),
    )
    shell_mutating: tuple[tuple[str, str], ...] = (
        (r"^\s*systemctl\s+(start|stop|restart|reload|enable|disable|mask)\b", "service state change"),
        (r"^\s*service\s+\S+\s+(start|stop|restart|reload)\b", "service state change"),
        (r"^\s*(apt|apt-get|yum|dnf|apk|pip|pip3|npm)\s+(install|remove|purge|upgrade|update)\b", "package change"),
        (r"^\s*docker\s+(stop|rm|kill|restart|run|exec|compose)\b", "container state change"),
        (r"^\s*patronictl\s+(switchover|failover|restart|reinit|edit-config)\b", "database topology change"),
        (r"^\s*rm\b", "file deletion"),
        (r"^\s*(mv|cp|truncate|tee|sed\s+-i)\b", "file modification"),
        (r"^\s*(useradd|userdel|passwd|chown|chmod)\b", "account or permission change"),
        (r"\b(>|>>)\s*/(etc|opt|srv|var)/", "write into a system path"),
        (r"^\s*(ip|ifconfig|route)\s+\w*\s*(add|del|set|flush)\b", "network configuration change"),
        (r"^\s*terraform\s+(apply|destroy|import|taint|state\s+rm)\b", "infrastructure change"),
        (r"^\s*ansible(-playbook)?\b", "configuration management run"),
    )

    # Tools whose every invocation is a read by nature.
    read_only_tools: frozenset[str] = frozenset({"prometheus", "loki", "patroni_status"})
    # Tools that always change something, whatever the arguments.
    always_mutating_tools: frozenset[str] = frozenset({"patroni_switchover"})

    extra_shell_blocked: tuple[tuple[str, str], ...] = field(default=())

    def with_blocked(self, pattern: str, reason: str) -> "Policy":
        """Return a policy with one more shell rule. Policies are immutable so
        that a caller cannot weaken the default set in place."""
        return replace(self, extra_shell_blocked=self.extra_shell_blocked + ((pattern, reason),))


_DEFAULT = Policy()


def default_policy() -> Policy:
    return _DEFAULT


def _subcommand(command: str, known: frozenset[str], depth: int = 2) -> list[str]:
    """The subcommand, found by looking for a verb the policy knows.

    Dropping flags is not enough: `--context prod get pods` would leave
    "prod" as the first word, and a policy keyed on position would classify a
    read as an unknown command. So scan for the first token that starts any
    policy entry, and take it plus the following non-flag tokens.
    """
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()

    first_words = {entry.split()[0] for entry in known}
    words: list[str] = []
    for token in tokens:
        low = token.lower()
        if not words:
            if low.startswith("-"):
                continue
            if low not in first_words:
                continue  # a flag value, or a binary name — keep looking
            words.append(low)
        else:
            if low.startswith("-"):
                continue
            words.append(low)
            if len(words) >= depth:
                break
    return words


def _match_set(words: list[str], candidates: frozenset[str]) -> str | None:
    """Longest matching prefix of `words` present in `candidates`."""
    for size in range(len(words), 0, -1):
        probe = " ".join(words[:size])
        if probe in candidates:
            return probe
    return None


def _classify_subcommand_tool(
    tool: str,
    command: str,
    blocked: frozenset[str],
    mutating: frozenset[str],
    read: frozenset[str],
    read_overrides: frozenset[str] = frozenset(),
) -> Decision:
    known = blocked | mutating | read | read_overrides
    words = _subcommand(command, known)
    if not words:
        return Decision(
            Verdict.BLOCKED,
            "no recognised subcommand — not in the policy",
            tool,
            command,
        )

    if hit := _match_set(words, blocked):
        reason = (
            "secrets are never read through the agent"
            if "secret" in hit
            else f"'{hit}' is blocked"
        )
        return Decision(Verdict.BLOCKED, reason, tool, command)

    # More specific than the mutating set: "rollout status" reads, while bare
    # "rollout restart" mutates.
    if hit := _match_set(words, read_overrides):
        return Decision(Verdict.READ, f"'{hit}' only reads", tool, command)

    if hit := _match_set(words, mutating):
        return Decision(Verdict.MUTATING, f"'{hit}' changes cluster state", tool, command)

    if hit := _match_set(words, read):
        return Decision(Verdict.READ, f"'{hit}' only reads", tool, command)

    # Unreachable in practice — _subcommand only returns known verbs — but a
    # policy where read/mutating/blocked disagree should fail closed, not open.
    return Decision(
        Verdict.BLOCKED,
        f"unknown {tool} subcommand '{words[0]}' — not in the policy",
        tool,
        command,
    )


def _classify_shell(tool: str, command: str, policy: Policy) -> Decision:
    # A shell is a way around every other rule: `ssh host kubectl delete
    # namespace prod` must not be classified by the shell policy, which knows
    # nothing about kubectl. Delegate to the tool's own rules instead — the
    # boundary has to hold whichever door the agent walks through.
    delegated = _delegate_embedded_tool(command, policy)
    if delegated is not None:
        return replace(delegated, tool=tool, command=command)

    for pattern, reason in policy.shell_blocked + policy.extra_shell_blocked:
        if re.search(pattern, command, re.IGNORECASE):
            return Decision(Verdict.BLOCKED, reason, tool, command)

    # Chained commands are classified by their most dangerous element: a
    # pipeline is only as safe as its worst link, and `read && mutate` is a
    # mutation.
    segments = [s for s in re.split(r"&&|\|\||;|\|", command) if s.strip()]
    if len(segments) > 1:
        decisions = [_classify_shell(tool, s, policy) for s in segments]
        for d in decisions:
            if d.verdict is Verdict.BLOCKED:
                return replace(d, command=command)
        for d in decisions:
            if d.verdict is Verdict.MUTATING:
                return replace(d, command=command, reason=f"{d.reason} (in a chained command)")
        return Decision(Verdict.READ, "all parts of the chain only read", tool, command)

    for pattern, reason in policy.shell_mutating:
        if re.search(pattern, command, re.IGNORECASE):
            return Decision(Verdict.MUTATING, reason, tool, command)

    return Decision(Verdict.READ, "no mutating or blocked pattern matched", tool, command)


_EMBEDDED_TOOL = re.compile(r"(?:^|\s)(kubectl|helm)\s+(.*)$", re.IGNORECASE)


def _delegate_embedded_tool(command: str, policy: Policy) -> Decision | None:
    """If a shell command invokes kubectl or helm, classify it as that tool."""
    match = _EMBEDDED_TOOL.search(command.strip())
    if not match:
        return None
    name, rest = match.group(1).lower(), match.group(2)
    if name == "kubectl":
        return _classify_subcommand_tool(
            "kubectl", rest,
            policy.kubectl_blocked, policy.kubectl_mutating, policy.kubectl_read,
            policy.kubectl_read_overrides,
        )
    return _classify_subcommand_tool(
        "helm", rest, policy.helm_blocked, policy.helm_mutating, policy.helm_read,
    )


def classify(tool: str, command: str, policy: Policy | None = None) -> Decision:
    """Classify one proposed tool call.

    `tool` is the tool name the agent asked for ("kubectl", "helm", "ssh",
    "bash", ...); `command` is everything it wants to pass to it.
    """
    policy = policy or _DEFAULT
    tool = tool.lower().strip()
    command = command.strip()

    if tool in policy.read_only_tools:
        return Decision(Verdict.READ, f"{tool} can only query", tool, command)
    if tool in policy.always_mutating_tools:
        return Decision(Verdict.MUTATING, f"{tool} always changes state", tool, command)

    if tool == "kubectl":
        return _classify_subcommand_tool(
            tool, command,
            policy.kubectl_blocked, policy.kubectl_mutating, policy.kubectl_read,
            policy.kubectl_read_overrides,
        )
    if tool == "helm":
        return _classify_subcommand_tool(
            tool, command,
            policy.helm_blocked, policy.helm_mutating, policy.helm_read,
        )
    if tool in {"ssh", "bash", "sh", "shell"}:
        return _classify_shell(tool, command, policy)

    # An unregistered tool is blocked rather than guessed at.
    return Decision(Verdict.BLOCKED, f"unknown tool '{tool}'", tool, command)
