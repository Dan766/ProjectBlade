"""Wrapper around the `claude` CLI for single structured-JSON calls.

Every call:
  - runs `claude -p` from an empty temp dir with isolation flags from pipeline.toml
  - sends the prompt on stdin (Windows command lines cap out around 32k chars)
  - asks for structured output via --json-schema, then re-validates locally
  - retries on CLI errors, parse errors and schema errors, feeding the error back
  - adds the call's cost to a process-wide tracker and aborts past budget_usd

Set PIPELINE_FAKE_LLM=1 to use pipeline.fake_llm instead (tests, dry pipelines).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from typing import Callable

import jsonschema

from . import config, fake_llm


class LLMError(Exception):
    """A call failed after all retries."""


class BudgetExceeded(LLMError):
    """Cumulative spend passed budget_usd."""


@dataclass
class LLMResult:
    data: object
    cost_usd: float
    attempts: int
    model: str
    errors: list[str] = field(default_factory=list)


class CostTracker:
    def __init__(self, budget_usd: float):
        self.budget_usd = budget_usd
        self.spent_usd = 0.0
        self._lock = threading.Lock()

    def check(self) -> None:
        with self._lock:
            if self.spent_usd >= self.budget_usd:
                raise BudgetExceeded(f"spent ${self.spent_usd:.4f} of ${self.budget_usd:.2f} budget")

    def add(self, usd: float) -> None:
        with self._lock:
            self.spent_usd += usd


# (args, stdin, cwd, timeout) -> (returncode, stdout, stderr). Swappable in tests.
Runner = Callable[[list[str], str, str, float], tuple[int, str, str]]


def _subprocess_runner(args: list[str], stdin: str, cwd: str, timeout: float) -> tuple[int, str, str]:
    proc = subprocess.run(
        args, input=stdin, cwd=cwd, capture_output=True, text=True, encoding="utf-8", timeout=timeout
    )
    return proc.returncode, proc.stdout, proc.stderr


_FENCE_RE = re.compile(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", re.DOTALL)


def parse_envelope(stdout: str) -> tuple[object, float]:
    """Return (payload, cost_usd) from `claude -p --output-format json` stdout.

    Prefers `structured_output`; falls back to parsing `result` text (code fences stripped).
    Raises ValueError with a readable message on any problem.
    """
    try:
        env = json.loads(stdout)
    except json.JSONDecodeError as e:
        raise ValueError(f"CLI stdout is not JSON: {e}") from e
    cost = float(env.get("total_cost_usd") or 0.0)
    if env.get("is_error") or env.get("subtype") != "success":
        raise _EnvelopeError(f"CLI reported error: subtype={env.get('subtype')} result={str(env.get('result'))[:300]}", cost)
    if env.get("structured_output") is not None:
        return env["structured_output"], cost
    text = env.get("result") or ""
    m = _FENCE_RE.match(text)
    if m:
        text = m.group(1)
    try:
        return json.loads(text), cost
    except json.JSONDecodeError as e:
        raise _EnvelopeError(f"result is not valid JSON: {e}", cost) from e


class _EnvelopeError(ValueError):
    def __init__(self, msg: str, cost: float):
        super().__init__(msg)
        self.cost = cost


class LLM:
    def __init__(self, cfg: dict | None = None, runner: Runner | None = None, fake: bool | None = None):
        cfg = cfg if cfg is not None else config.load()["llm"]
        self.cfg = cfg
        self.runner = runner or _subprocess_runner
        self.fake = fake if fake is not None else os.environ.get("PIPELINE_FAKE_LLM") == "1"
        self.tracker = CostTracker(float(cfg["budget_usd"]))
        self._binary: str | None = None

    def _claude_binary(self) -> str:
        if self._binary is None:
            found = shutil.which("claude")
            if not found:
                raise LLMError("`claude` CLI not found on PATH")
            self._binary = found
        return self._binary

    def build_args(self, schema: dict) -> list[str]:
        c = self.cfg
        return [
            self._claude_binary(), "-p",
            "--model", c["model"],
            "--output-format", "json",
            "--system-prompt", c["system_prompt"],
            "--json-schema", json.dumps(schema, separators=(",", ":")),
            "--max-budget-usd", str(c["per_call_budget_usd"]),
            *c.get("extra_args", []),
        ]

    def call_json(self, prompt: str, schema: dict) -> LLMResult:
        """Run one prompt and return data that validates against `schema`."""
        if self.fake:
            data = fake_llm.generate(schema, seed_text=prompt)
            jsonschema.validate(data, schema)
            return LLMResult(data=data, cost_usd=0.0, attempts=1, model="fake")

        args = self.build_args(schema)
        errors: list[str] = []
        total_cost = 0.0
        attempts = 1 + int(self.cfg["retries"])
        prompt = with_json_instruction(prompt, schema)
        current_prompt = prompt
        # ignore_cleanup_errors: on Windows a lingering claude child process can keep the empty dir
        # locked for a moment; failing the whole job (or run) over that is wrong (seen in 0.6 pilot).
        with tempfile.TemporaryDirectory(prefix="pipeline_llm_", ignore_cleanup_errors=True) as cwd:
            for attempt in range(1, attempts + 1):
                self.tracker.check()
                try:
                    code, out, err = self.runner(args, current_prompt, cwd, float(self.cfg["timeout_s"]))
                except subprocess.TimeoutExpired:
                    errors.append(f"attempt {attempt}: timeout")
                    continue
                if code != 0 and not out.strip():
                    errors.append(f"attempt {attempt}: exit {code}: {err.strip()[:300]}")
                    continue
                try:
                    data, cost = parse_envelope(out)
                except _EnvelopeError as e:
                    self.tracker.add(e.cost)
                    total_cost += e.cost
                    errors.append(f"attempt {attempt}: {e}")
                    current_prompt = _with_feedback(prompt, str(e))
                    continue
                except ValueError as e:
                    errors.append(f"attempt {attempt}: {e}")
                    continue
                self.tracker.add(cost)
                total_cost += cost
                try:
                    jsonschema.validate(data, schema)
                except jsonschema.ValidationError as e:
                    errors.append(f"attempt {attempt}: schema: {e.message}")
                    current_prompt = _with_feedback(prompt, f"schema violation: {e.message}")
                    continue
                return LLMResult(data=data, cost_usd=total_cost, attempts=attempt, model=self.cfg["model"], errors=errors)
        raise LLMError("; ".join(errors))


def with_json_instruction(prompt: str, schema: dict) -> str:
    # --json-schema alone is not enough: if the prompt doesn't ask for JSON, Haiku often
    # answers in markdown and never emits structured_output (seen in milestone 0.1 smoke runs).
    # Not part of the job's prompt_hash (jobs.py hashes the template render), so wording changes here
    # never invalidate finished jobs.
    return (
        f"{prompt}\n\nRespond with a single JSON value matching this JSON Schema, and nothing else:\n"
        f"{json.dumps(schema, separators=(',', ':'))}\n"
        "Inside text values never use the double-quote character; use single quotes for quoted speech."
    )


def _with_feedback(prompt: str, error: str) -> str:
    hint = ""
    if "not valid JSON" in error:
        # 0.6 full run: a probe of a failing job showed relationship objects nested INSIDE each other
        # with a closing brace lost (not stray quotes, as first assumed).
        hint = (" Usually a bracket problem: close each object with } before starting the next key at the"
                " same level, keep every top-level key at the top level, and use no double quotes"
                " inside lines.")
    return f"{prompt}\n\nYour previous output failed: {error}.{hint}\nReturn ONLY valid JSON matching the schema."
