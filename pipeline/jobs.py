"""Job model and the resumable, threaded job runner.

A Job is one model call: a prompt template + variables + an output schema.
Its output lands in out/raw/<stage>/<job_id>.json as {"meta": {...}, "data": ...}.

Resume rule: a job is skipped when its output file exists and meta.prompt_hash matches.
prompt_hash covers the template version, the rendered prompt, the schema and the model,
so editing a template (or a job's vars) reruns exactly the jobs it affects.

Prompt templates (pipeline/prompts/*.md):
  - first line must be a version header:  <!-- version: 1 -->
  - {{var}} is substituted from Job.vars (non-strings are JSON-encoded)
  - single-brace {player} placeholders pass through untouched, they are game placeholders
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from . import config
from .llm import BudgetExceeded, LLMError

PROMPTS_DIR = config.PIPELINE_DIR / "prompts"
RAW_DIR = config.OUT_DIR / "raw"
DRYRUN_DIR = config.OUT_DIR / "dryrun"

_VERSION_RE = re.compile(r"^\s*<!--\s*version:\s*(\S+)\s*-->\s*\n")
_VAR_RE = re.compile(r"\{\{\s*(\w+)\s*\}\}")
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


class TemplateError(ValueError):
    pass


@dataclass(frozen=True)
class Job:
    stage: str
    job_id: str
    prompt_file: str          # file name in prompts/
    vars: dict = field(default_factory=dict, hash=False, compare=False)
    schema: str = ""          # file name in schemas/
    schema_inline: dict | None = field(default=None, hash=False, compare=False)   # overrides `schema`


@dataclass
class Rendered:
    job: Job
    prompt: str
    schema: dict
    prompt_hash: str


@dataclass
class RunReport:
    total: int = 0
    ran: int = 0
    skipped: int = 0
    failed: int = 0
    not_run: int = 0          # stopped by the budget cap
    cost_usd: float = 0.0
    failed_ids: list[str] = field(default_factory=list)
    budget_stopped: bool = False

    def line(self) -> str:
        s = (f"total={self.total} ran={self.ran} skipped={self.skipped} failed={self.failed} "
             f"not_run={self.not_run} cost_usd={self.cost_usd:.4f}")
        return s + (" BUDGET CAP HIT" if self.budget_stopped else "")


def render_template(text: str, variables: dict, name: str = "template") -> tuple[str, str]:
    """Return (version, rendered prompt). Raises TemplateError on a missing header or variable."""
    m = _VERSION_RE.match(text)
    if not m:
        raise TemplateError(f"{name}: first line must be '<!-- version: N -->'")
    body = text[m.end():]
    missing = sorted({v for v in _VAR_RE.findall(body) if v not in variables})
    if missing:
        raise TemplateError(f"{name}: no value for {', '.join('{{' + v + '}}' for v in missing)}")

    def sub(match: re.Match) -> str:
        v = variables[match.group(1)]
        return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)

    return m.group(1), _VAR_RE.sub(sub, body).strip() + "\n"


def prompt_hash(version: str, prompt: str, schema: dict, model: str) -> str:
    h = hashlib.sha256()
    for part in (version, prompt, json.dumps(schema, sort_keys=True), model):
        h.update(part.encode("utf-8"))
        h.update(b"\0")
    return h.hexdigest()


class Runner:
    def __init__(self, llm, *, model: str, prompts_dir: Path = PROMPTS_DIR, schemas_dir: Path = config.SCHEMA_DIR,
                 raw_dir: Path = RAW_DIR, dryrun_dir: Path = DRYRUN_DIR, workers: int = 8,
                 force: bool = False, dry_run: bool = False, log: Callable[[str], None] | None = None):
        self.llm = llm
        self.model = model
        self.prompts_dir, self.schemas_dir = Path(prompts_dir), Path(schemas_dir)
        self.raw_dir, self.dryrun_dir = Path(raw_dir), Path(dryrun_dir)
        self.workers = workers
        self.force = force
        self.dry_run = dry_run
        self.log = log or (lambda msg: print(msg, file=sys.stderr, flush=True))
        self._lock = threading.Lock()
        self._templates: dict[str, str] = {}
        self._schemas: dict[str, dict] = {}

    # --- rendering -----------------------------------------------------------

    def render(self, job: Job) -> Rendered:
        if not _SAFE_ID_RE.match(job.job_id) or not _SAFE_ID_RE.match(job.stage):
            raise ValueError(f"unsafe stage/job_id: {job.stage}/{job.job_id}")
        if job.prompt_file not in self._templates:
            self._templates[job.prompt_file] = (self.prompts_dir / job.prompt_file).read_text(encoding="utf-8")
        if job.schema_inline is None and job.schema not in self._schemas:
            self._schemas[job.schema] = json.loads((self.schemas_dir / job.schema).read_text(encoding="utf-8"))
        version, prompt = render_template(self._templates[job.prompt_file], job.vars, job.prompt_file)
        schema = job.schema_inline if job.schema_inline is not None else self._schemas[job.schema]
        return Rendered(job, prompt, schema, prompt_hash(version, prompt, schema, self.model))

    def output_path(self, job: Job) -> Path:
        return self.raw_dir / job.stage / f"{job.job_id}.json"

    def is_current(self, r: Rendered) -> bool:
        path = self.output_path(r.job)
        if self.force or not path.exists():
            return False
        try:
            return json.loads(path.read_text(encoding="utf-8"))["meta"]["prompt_hash"] == r.prompt_hash
        except (json.JSONDecodeError, KeyError, OSError):
            return False

    # --- running -------------------------------------------------------------

    def run(self, jobs: list[Job]) -> RunReport:
        ids = [j.job_id for j in jobs]
        dupes = {i for i in ids if ids.count(i) > 1}
        if dupes:
            raise ValueError(f"duplicate job ids: {sorted(dupes)}")
        # Render everything first so template mistakes fail before any money is spent.
        rendered = [self.render(j) for j in jobs]
        report = RunReport(total=len(rendered))

        if self.dry_run:
            for r in rendered:
                _atomic_write(self.dryrun_dir / r.job.stage / f"{r.job.job_id}.md", r.prompt)
            report.skipped = len(rendered)
            self.log(f"dry run: wrote {len(rendered)} prompt(s) to {self.dryrun_dir}")
            return report

        todo = [r for r in rendered if not self.is_current(r)]
        report.skipped = len(rendered) - len(todo)
        if not todo:
            self.log(f"[{jobs[0].stage if jobs else '-'}] nothing to do, {report.skipped} job(s) up to date")
            return report

        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            futures = {pool.submit(self._run_one, r): r for r in todo}
            for fut in as_completed(futures):
                r = futures[fut]
                status, cost, err = fut.result()
                with self._lock:
                    report.cost_usd += cost
                    if status == "ok":
                        report.ran += 1
                    elif status == "budget":
                        report.not_run += 1
                        report.budget_stopped = True
                    else:
                        report.failed += 1
                        report.failed_ids.append(r.job.job_id)
                    done = report.ran + report.failed + report.not_run
                    self.log(f"[{r.job.stage}] {done}/{len(todo)} {status:<6} {r.job.job_id}"
                             f"{'  ' + err[:160] if err else ''}  (cost so far ${report.cost_usd:.4f})")
        report.failed_ids.sort()
        return report

    def _run_one(self, r: Rendered) -> tuple[str, float, str]:
        try:
            res = self.llm.call_json(r.prompt, r.schema)
        except BudgetExceeded as e:
            return "budget", 0.0, str(e)
        except LLMError as e:
            self._log_failure(r, str(e))
            return "failed", 0.0, str(e)
        except Exception as e:  # one broken job must never take down the whole run
            msg = f"unexpected {type(e).__name__}: {e}"
            self._log_failure(r, msg)
            return "failed", 0.0, msg
        meta = {
            "job_id": r.job.job_id, "stage": r.job.stage, "prompt_file": r.job.prompt_file,
            "prompt_hash": r.prompt_hash, "model": res.model, "cost_usd": res.cost_usd,
            "attempts": res.attempts, "retry_errors": res.errors, "created_at": _now(),
        }
        _atomic_write(self.output_path(r.job), json.dumps({"meta": meta, "data": res.data}, indent=2, ensure_ascii=False))
        return "ok", res.cost_usd, ""

    def _log_failure(self, r: Rendered, error: str) -> None:
        path = self.raw_dir / r.job.stage / "_failed.jsonl"
        entry = {"job_id": r.job.job_id, "prompt_hash": r.prompt_hash, "error": error, "at": _now()}
        with self._lock:
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def select(jobs: list[Job], only: list[str] | None = None, limit: int | None = None) -> list[Job]:
    if only:
        wanted = set(only)
        unknown = wanted - {j.job_id for j in jobs}
        if unknown:
            raise ValueError(f"unknown job id(s): {sorted(unknown)}")
        jobs = [j for j in jobs if j.job_id in wanted]
    return jobs[:limit] if limit else jobs


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
