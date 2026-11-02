"""Stage registry: stage name -> Stage(jobs, post).

`jobs(cfg)` returns the stage's Jobs. Optional `post(cfg, raw_dir, out_dir)` runs after the jobs
(skipped on --dry-run) and turns raw outputs into out/validated/<stage>/ files; it returns a
PostResult whose errors make `run` exit non-zero.

Each later milestone adds its stage here (personas 0.5, pools 0.6, ...).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from ..jobs import Job


@dataclass
class PostResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    summary: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Stage:
    jobs: Callable[[dict], list[Job]]
    post: Callable[[dict, Path, Path], PostResult] | None = None


from . import conversations, personas, pools, signatures, smoke, world  # noqa: E402  (modules import PostResult from here)

STAGES: dict[str, Stage] = {
    "smoke": Stage(smoke.jobs),
    "world": Stage(world.jobs, world.post),
    "personas": Stage(personas.jobs, personas.post),
    "pools": Stage(pools.jobs, pools.post),
    "signatures": Stage(signatures.jobs, signatures.post),
    "conversations": Stage(conversations.jobs, conversations.post),
}
