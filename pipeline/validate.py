"""`python -m pipeline validate`: re-run every stage's post step in dependency order, then checks
that span stages. Writes out/reports/validation.json; any error makes the command exit 1.

A stage whose post step errors marks every later stage as skipped (they would read stale inputs).

Cross-stage checks:
  errors   - signatures / conversations reference persona ids that don't exist
  warnings - a line pairs {player}/{rival} with a gendered word (he/she/lady/lord...): it may
             assume the gender of the human player or another player
           - an archetype pool line contains a real persona's username (pools must stay generic)
           - the same line (normalized) appears in more than one archetype's pool
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path

from . import textcheck
from .jobs import _atomic_write
from .stages import STAGES, PostResult

ORDER = ["world", "personas", "pools", "signatures", "conversations"]
GENDERED = re.compile(r"\b(he|she|him|her|his|hers|lady|lord|man|woman|sir|madam|milady|milord)\b", re.I)
EXAMPLES_PER_CHECK = 10


def _load(path: Path):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def all_lines(out_dir: Path) -> list[tuple[str, str]]:
    """(source label, text) for every validated chat line."""
    lines = []
    for f in sorted((out_dir / "pools").glob("*.json")):
        for eid, rels in json.loads(f.read_text(encoding="utf-8")).items():
            for rel, chans in rels.items():
                for ch, ls in chans.items():
                    lines += [(f"pool {f.stem}/{eid}/{rel}/{ch}", x["text"]) for x in ls]
    sig = _load(out_dir / "signatures" / "signatures.json") or {}
    for pid, s in sig.items():
        for eid, ls in s["signature"].items():
            lines += [(f"signature {pid}/{eid}", x["text"]) for x in ls]
    for t in _load(out_dir / "conversations" / "conversations.json") or []:
        lines += [(f"conversation {t['id']}", x["text"]) for x in t["lines"]]
    return lines


def cross_checks(cfg: dict, out_dir: Path) -> PostResult:
    res = PostResult()
    personas = _load(out_dir / "personas" / "personas.json") or []
    ids = {p["id"] for p in personas}

    sig = _load(out_dir / "signatures" / "signatures.json")
    if sig is not None:
        unknown = sorted(set(sig) - ids)
        missing = sorted(ids - set(sig))
        if unknown:
            res.errors.append(f"signatures for unknown persona ids: {unknown[:EXAMPLES_PER_CHECK]}")
        if missing:
            res.errors.append(f"personas without signatures: {missing[:EXAMPLES_PER_CHECK]}")
    for t in _load(out_dir / "conversations" / "conversations.json") or []:
        bad = sorted(set(t["participants"]) - ids)
        if bad:
            res.errors.append(f"conversation {t['id']} has unknown participants {bad}")

    lines = all_lines(out_dir)
    gendered = [(src, t) for src, t in lines if textcheck.assumes_gender(t)]
    if gendered:
        res.warnings.append(f"{len(gendered)} line(s) assume the gender of the player or a rival, e.g. "
                            + "; ".join(f"[{s}] {t!r}" for s, t in gendered[:EXAMPLES_PER_CHECK]))

    names = [p["username"] for p in personas if len(p["username"]) >= 4]
    if names:
        name_re = re.compile(r"\b(" + "|".join(re.escape(n) for n in names) + r")\b", re.I)
        named = [(src, t) for src, t in lines if src.startswith("pool ") and name_re.search(t)]
        if named:
            res.warnings.append(f"{len(named)} pool line(s) name a specific player, e.g. "
                                + "; ".join(f"[{s}] {t!r}" for s, t in named[:EXAMPLES_PER_CHECK]))

    owners: dict[str, set[str]] = defaultdict(set)
    for src, t in lines:
        if src.startswith("pool "):
            owners[textcheck.normalize(t)].add(src.split()[1].split("/")[0])
    shared = {k: v for k, v in owners.items() if len(v) > 1}
    if shared:
        res.warnings.append(f"{len(shared)} line(s) appear in more than one archetype's pool, e.g. "
                            + "; ".join(f"{k!r} in {sorted(v)}" for k, v in list(shared.items())[:EXAMPLES_PER_CHECK]))
    res.summary.append(f"cross-stage: {len(lines)} lines checked")
    return res


def validate_all(cfg: dict, raw_dir: Path, out_dir: Path, reports_dir: Path) -> tuple[bool, dict]:
    results: dict[str, dict] = {}
    blocked_by = None
    for name in ORDER:
        if blocked_by:
            results[name] = {"skipped": f"depends on {blocked_by}, which has errors"}
            continue
        try:
            r = STAGES[name].post(cfg, raw_dir, out_dir)
        except ValueError as e:
            r = PostResult(errors=[str(e)])
        results[name] = {"errors": r.errors, "warnings": r.warnings, "summary": r.summary}
        if r.errors:
            blocked_by = name
    if blocked_by is None:
        c = cross_checks(cfg, out_dir)
        results["cross"] = {"errors": c.errors, "warnings": c.warnings, "summary": c.summary}
    ok = not any(v.get("errors") or v.get("skipped") for v in results.values())
    _atomic_write(reports_dir / "validation.json", json.dumps(results, indent=2, ensure_ascii=False))
    return ok, results
