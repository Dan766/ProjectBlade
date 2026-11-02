"""Tiny real stage (3 jobs, ~1 cent) for checking the runner end to end against Haiku."""
from __future__ import annotations

from ..jobs import Job

ARCHETYPES = ("griefer", "trader", "roleplayer")


def jobs(cfg: dict) -> list[Job]:
    out = []
    for aid in ARCHETYPES:
        a = cfg["archetypes"][aid]
        out.append(Job(
            stage="smoke", job_id=f"smoke_{aid}", prompt_file="smoke.md", schema="smoke_line.schema.json",
            vars={"label": a["label"], "tone": " ".join(a["tone"].split()), "chat_style": a["chat_style"]},
        ))
    return out
