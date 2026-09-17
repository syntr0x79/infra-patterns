"""Decide whether a command an LLM proposed is allowed to run.

The policy is data, the decision is a pure function, and neither can be talked
out of its answer by anything in the model's context.

    >>> from cmdpolicy import classify, Verdict
    >>> classify("kubectl", "get pods -n prod").verdict
    <Verdict.READ: 'read'>
    >>> classify("kubectl", "delete namespace prod").verdict
    <Verdict.BLOCKED: 'blocked'>
    >>> classify("kubectl", "get secret db-password").reason
    'secrets are never read through the agent'
"""

from .policy import (
    Decision,
    Policy,
    Verdict,
    classify,
    default_policy,
)

__all__ = ["Decision", "Policy", "Verdict", "classify", "default_policy"]
__version__ = "1.0.0"
