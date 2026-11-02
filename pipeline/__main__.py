"""CLI entry point: python -m pipeline <command>."""
from __future__ import annotations

import argparse
import json
import sys

from . import config, jobs
from .llm import LLM, LLMError
from .stages import STAGES

SMOKE_SCHEMA = json.loads((config.SCHEMA_DIR / "smoke_line.schema.json").read_text(encoding="utf-8"))

SMOKE_PROMPT = (
    "Invent one player on a medieval sandbox game server. Give a gamer-style username and one "
    "short line they would type in global chat after losing a battle to {player}. "
    "Keep the literal placeholder {player} in the line."
)

# Commands from docs/specs/pipeline.md section 3 that later milestones implement.
PLANNED: dict[str, str] = {}


def cmd_smoke(_args: argparse.Namespace) -> int:
    llm = LLM()
    try:
        res = llm.call_json(SMOKE_PROMPT, SMOKE_SCHEMA)
    except LLMError as e:
        print(f"smoke FAILED: {e}", file=sys.stderr)
        return 1
    print(json.dumps(res.data, indent=2, ensure_ascii=False))
    print(f"model={res.model} attempts={res.attempts} cost_usd={res.cost_usd:.6f}")
    for err in res.errors:
        print(f"  retried: {err}")
    return 0


def cmd_config(_args: argparse.Namespace) -> int:
    cfg = config.load_all()
    errs = config.check(cfg)
    for k, v in config.summary(cfg).items():
        print(f"{k:>18}: {v}")
    if errs:
        print(f"\n{len(errs)} config problem(s):", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("\nconfig OK")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    if args.stage not in STAGES:
        print(f"unknown stage {args.stage!r}; available: {', '.join(sorted(STAGES))}", file=sys.stderr)
        return 2
    cfg = config.load_all()
    errs = config.check(cfg)
    if errs:
        print("config has problems, run `python -m pipeline config`", file=sys.stderr)
        return 1
    llm = LLM(cfg=cfg["pipeline"]["llm"])
    runner = jobs.Runner(
        llm, model="fake" if llm.fake else cfg["pipeline"]["llm"]["model"],
        workers=args.jobs or cfg["pipeline"]["run"]["jobs"], force=args.force, dry_run=args.dry_run,
    )
    stage = STAGES[args.stage]
    try:
        selected = jobs.select(stage.jobs(cfg), only=args.only, limit=args.limit)
        report = runner.run(selected)
    except (ValueError, jobs.TemplateError) as e:
        print(f"run FAILED before any call: {e}", file=sys.stderr)
        return 1
    print(report.line())
    if report.failed_ids:
        print(f"failed: {', '.join(report.failed_ids)} (details in out/raw/{args.stage}/_failed.jsonl)")
    ok = not (report.failed or report.budget_stopped)
    if stage.post and not args.dry_run:
        post = stage.post(cfg, runner.raw_dir, config.OUT_DIR / "validated")
        for line in post.summary:
            print(line)
        for w in post.warnings:
            print(f"  warning: {w}")
        for e in post.errors:
            print(f"  ERROR: {e}", file=sys.stderr)
        ok = ok and not post.errors
    return 0 if ok else 1


def _print_pool(args, pool: dict, rng) -> int:
    events = [args.event] if args.event else sorted(pool)
    if args.event and args.event not in pool:
        print(f"{args.who!r} has no lines for {args.event!r}; has: {', '.join(sorted(pool))}", file=sys.stderr)
        return 1
    for eid in events:
        print(f"\n== {args.who} / {eid}")
        for rel, chans in pool[eid].items():
            for ch, lines in chans.items():
                print(f"  -- {rel} / {ch} ({len(lines)} lines)")
                for line in rng.sample(lines, min(args.n, len(lines))):
                    print(f"     {line['text']}")
    return 0


def cmd_sample(args: argparse.Namespace) -> int:
    """Random lines for human review: an archetype pool, a persona's signature lines (by id or
    username), or `conversations` (n random threads)."""
    import random
    rng = random.Random(args.seed)
    vdir = config.OUT_DIR / "validated"
    pool_file = vdir / "pools" / f"{args.who}.json"
    if pool_file.exists():
        return _print_pool(args, json.loads(pool_file.read_text(encoding="utf-8")), rng)

    personas_file = vdir / "personas" / "personas.json"
    personas = json.loads(personas_file.read_text(encoding="utf-8")) if personas_file.exists() else []
    names = {p["id"]: p["username"] for p in personas}

    if args.who == "conversations":
        f = vdir / "conversations" / "conversations.json"
        if not f.exists():
            print("no conversations yet; run `python -m pipeline run conversations`", file=sys.stderr)
            return 1
        threads = json.loads(f.read_text(encoding="utf-8"))
        for t in rng.sample(threads, min(args.n, len(threads))):
            print(f"\n== {t['id']} ({t['trigger']}): {t['topic']}")
            for ln in t["lines"]:
                print(f"   +{ln['delay_s']:>2}s [{names.get(ln['speaker'], ln['speaker'])}] {ln['text']}")
        return 0

    p = next((p for p in personas if args.who in (p["id"], p["username"])), None)
    sig_file = vdir / "signatures" / "signatures.json"
    if p and sig_file.exists():
        sig = json.loads(sig_file.read_text(encoding="utf-8")).get(p["id"])
        if sig:
            print(f"\n{p['username']} ({p['id']}, {p['archetype']}): {p['backstory']}")
            for eid, lines in sig["signature"].items():
                if args.event and eid != args.event:
                    continue
                print(f"  == {eid}")
                for x in rng.sample(lines, min(args.n, len(lines))):
                    print(f"     [{x['rel']}/{x['channel']}] {x['text']}")
            return 0
    print(f"nothing to sample for {args.who!r}: not an archetype with a pool, a persona with signatures, "
          f"or 'conversations'", file=sys.stderr)
    return 1


def _print_findings(results: dict) -> bool:
    ok = True
    for name, r in results.items():
        if r.get("skipped"):
            print(f"[{name}] SKIPPED: {r['skipped']}")
            ok = False
            continue
        print(f"[{name}] {len(r['errors'])} error(s), {len(r['warnings'])} warning(s)")
        for line in r["summary"]:
            print(f"   {line}")
        for e in r["errors"]:
            print(f"   ERROR: {e}", file=sys.stderr)
            ok = False
    return ok


def cmd_validate(_args: argparse.Namespace) -> int:
    from . import validate
    cfg = config.load_all()
    reports = config.OUT_DIR / "reports"
    ok, results = validate.validate_all(cfg, config.OUT_DIR / "raw", config.OUT_DIR / "validated", reports)
    _print_findings(results)
    for w in results.get("cross", {}).get("warnings", []):
        print(f"   cross warning: {w[:400]}")
    print(f"\nfull details: {reports / 'validation.json'}")
    print("validate OK" if ok else "validate FAILED")
    return 0 if ok else 1


def cmd_dedupe(_args: argparse.Namespace) -> int:
    """Duplicate report only: within-cell and signature-vs-pool duplicates are already dropped by the
    stage post steps (run `validate`); this lists the cross-archetype ones that are kept on purpose."""
    from . import validate
    cfg = config.load_all()
    res = validate.cross_checks(cfg, config.OUT_DIR / "validated")
    shared = [w for w in res.warnings if "more than one archetype" in w]
    print(shared[0] if shared else "no line appears in more than one archetype's pool")
    return 0


def cmd_report(_args: argparse.Namespace) -> int:
    from . import report
    cfg = config.load_all()
    r = report.build(cfg, config.OUT_DIR / "raw", config.OUT_DIR / "validated", config.OUT_DIR / "reports")
    for k, v in r["counts"].items():
        print(f"{k:>22}: {v}")
    cov = r["pool_coverage"]
    print(f"{'pool cells':>22}: {cov['cells'] - cov['gaps']}/{cov['cells']} at min_variants")
    for g in cov["gap_list"][:15]:
        print(f"{'':>24}gap {g}")
    print(f"{'signature gaps':>22}: {len(r['signature_gaps'])}")
    print(f"{'raw job outputs':>22}: {r['raw']['job_outputs']} (total cost ${r['raw']['total_cost_usd']:.2f})")
    print(f"{'open failures':>22}: {', '.join(r['raw']['open_failures']) or 'none'}")
    return 0 if not (cov["gaps"] or r["signature_gaps"] or r["raw"]["open_failures"]) else 1


def cmd_bundle(_args: argparse.Namespace) -> int:
    from . import bundle, validate
    cfg = config.load_all()
    ok, results = validate.validate_all(cfg, config.OUT_DIR / "raw", config.OUT_DIR / "validated",
                                        config.OUT_DIR / "reports")
    if not ok:
        _print_findings(results)
        print("bundle REFUSED: validate has errors (see above)", file=sys.stderr)
        return 1
    manifest, errs = bundle.bundle(cfg, config.OUT_DIR / "validated")
    if errs:
        for e in errs[:30]:
            print(f"  CONTRACT ERROR: {e}", file=sys.stderr)
        print(f"bundle FAILED contract checks; live bundle untouched, inspect {bundle.GAME_DATA_DIR / 'generated.tmp'}",
              file=sys.stderr)
        return 1
    for k, v in manifest["counts"].items():
        print(f"{k:>16}: {v}")
    print(f"bundle OK: {len(manifest['files'])} files -> {bundle.GAME_DATA_DIR / 'generated'}")
    return 0


ALL_STAGES = ["world", "personas", "pools", "signatures", "conversations"]


def cmd_all(args: argparse.Namespace) -> int:
    """Every stage in order (resumable, so finished jobs are skipped), then report and bundle."""
    for stage in ALL_STAGES:
        print(f"\n### run {stage}")
        rc = cmd_run(argparse.Namespace(stage=stage, limit=None, only=None, force=False,
                                        jobs=args.jobs, dry_run=False))
        if rc:
            print(f"all STOPPED at {stage}", file=sys.stderr)
            return rc
    print("\n### report")
    cmd_report(args)
    print("\n### bundle")
    return cmd_bundle(args)


def main(argv: list[str] | None = None) -> int:
    # Generated names use accented letters (e.g. Dubravica's č); the Windows console default is cp1252.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(prog="python -m pipeline")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("smoke", help="one tiny real call; prints parsed JSON and cost")
    sub.add_parser("config", help="load and cross-check config/*.toml; print generation sizing")
    run = sub.add_parser("run", help="run one stage's jobs (resumable)")
    run.add_argument("stage")
    run.add_argument("--limit", type=int, help="only the first N jobs")
    run.add_argument("--only", action="append", metavar="JOB_ID", help="only this job id (repeatable)")
    run.add_argument("--force", action="store_true", help="regenerate even if output is up to date")
    run.add_argument("--jobs", type=int, help="parallel workers (default from pipeline.toml)")
    run.add_argument("--dry-run", action="store_true", help="write rendered prompts to out/dryrun/, no calls")
    sub.add_parser("validate", help="re-run every stage's checks + cross-stage checks")
    sub.add_parser("dedupe", help="report lines shared across archetype pools")
    sub.add_parser("report", help="coverage gaps, counts, total cost, open failures")
    sub.add_parser("bundle", help="validate, then write game/data/generated (the Godot contract)")
    all_ = sub.add_parser("all", help="run every stage, report, bundle")
    all_.add_argument("--jobs", type=int, help="parallel workers (default from pipeline.toml)")
    sample = sub.add_parser("sample", help="print random generated lines for human review")
    sample.add_argument("who", help="archetype id (griefer), persona id or username, or 'conversations'")
    sample.add_argument("event", nargs="?", help="one event id (default: all)")
    sample.add_argument("-n", type=int, default=3, help="lines per cell (default 3)")
    sample.add_argument("--seed", type=int, default=None, help="fix the random pick")
    for name, milestone in PLANNED.items():
        sub.add_parser(name, help=f"(not yet implemented, milestone {milestone})")
    args = p.parse_args(argv)
    if args.command == "smoke":
        return cmd_smoke(args)
    if args.command == "config":
        return cmd_config(args)
    if args.command == "run":
        return cmd_run(args)
    if args.command == "sample":
        return cmd_sample(args)
    if args.command in ("validate", "dedupe", "report", "bundle", "all"):
        return {"validate": cmd_validate, "dedupe": cmd_dedupe, "report": cmd_report,
                "bundle": cmd_bundle, "all": cmd_all}[args.command](args)
    print(f"`{args.command}` is not implemented yet (milestone {PLANNED[args.command]}).", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
