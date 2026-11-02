"""`python -m pipeline report`: coverage, counts and cost, from out/validated and out/raw.

Coverage looks at the FULL taxonomy (every archetype x event x relationship x channel), whatever
scale.pilot says, so a pilot-only pool shows up as gaps. Writes out/reports/report.json.
"""
from __future__ import annotations

import json
from pathlib import Path

from .config import event_bands
from .jobs import _atomic_write
from .stages.signatures import KEEP_MIN, sig_events


def _load(path: Path):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def pool_coverage(cfg: dict, out_dir: Path) -> tuple[int, list[str]]:
    """(total cells, gaps) where a gap is a cell with fewer lines than its min_variants."""
    mv = cfg["pipeline"]["scale"]["min_variants"]
    total, gaps = 0, []
    for aid in sorted(cfg["archetypes"]):
        pool = _load(out_dir / "pools" / f"{aid}.json") or {}
        for eid, ev in sorted(cfg["events"]["events"].items()):
            for rel in event_bands(ev):
                for ch in ev["channels"]:
                    total += 1
                    have = len(pool.get(eid, {}).get(rel, {}).get(ch, []))
                    if have < mv[ev["frequency"]]:
                        gaps.append(f"{aid}/{eid}/{rel}/{ch}: {have}/{mv[ev['frequency']]}")
    return total, gaps


def signature_gaps(cfg: dict, out_dir: Path) -> list[str]:
    personas = _load(out_dir / "personas" / "personas.json") or []
    sig = _load(out_dir / "signatures" / "signatures.json") or {}
    gaps = []
    for p in personas:
        have = sig.get(p["id"], {}).get("signature", {})
        for eid in sig_events(cfg, p):
            if len(have.get(eid, [])) < KEEP_MIN:
                gaps.append(f"{p['id']}/{eid}: {len(have.get(eid, []))}/{KEEP_MIN}")
    return gaps


def raw_status(raw_dir: Path) -> tuple[float, int, list[str]]:
    """(total cost, job outputs, failed job ids that still have no output)."""
    cost, n, open_failures = 0.0, 0, []
    for stage_dir in sorted(p for p in raw_dir.glob("*") if p.is_dir()):
        for f in stage_dir.glob("*.json"):
            cost += float(json.loads(f.read_text(encoding="utf-8"))["meta"].get("cost_usd") or 0)
            n += 1
        failed = stage_dir / "_failed.jsonl"
        if failed.exists():
            ids = {json.loads(ln)["job_id"] for ln in failed.read_text(encoding="utf-8").splitlines() if ln.strip()}
            open_failures += [f"{stage_dir.name}/{j}" for j in sorted(ids) if not (stage_dir / f"{j}.json").exists()]
    return cost, n, open_failures


def build(cfg: dict, raw_dir: Path, out_dir: Path, reports_dir: Path) -> dict:
    total_cells, gaps = pool_coverage(cfg, out_dir)
    sig_gaps = signature_gaps(cfg, out_dir)
    cost, n_jobs, open_failures = raw_status(raw_dir)
    world = _load(out_dir / "world" / "settlements.json") or []
    pools = {f.stem: _load(f) for f in (out_dir / "pools").glob("*.json")}
    sig = _load(out_dir / "signatures" / "signatures.json") or {}
    convs = _load(out_dir / "conversations" / "conversations.json") or []
    report = {
        "counts": {
            "factions": len(_load(out_dir / "world" / "factions.json") or []),
            "settlements": len(world),
            "personas": len(_load(out_dir / "personas" / "personas.json") or []),
            "pool_lines": sum(len(ls) for p in pools.values() for r in p.values() for c in r.values() for ls in c.values()),
            "signature_lines": sum(len(ls) for s in sig.values() for ls in s["signature"].values()),
            "conversation_threads": len(convs),
            "conversation_lines": sum(len(t["lines"]) for t in convs),
        },
        "pool_coverage": {"cells": total_cells, "gaps": len(gaps), "gap_list": gaps},
        "signature_gaps": sig_gaps,
        "raw": {"job_outputs": n_jobs, "total_cost_usd": round(cost, 4), "open_failures": open_failures},
    }
    _atomic_write(reports_dir / "report.json", json.dumps(report, indent=2, ensure_ascii=False))
    return report
