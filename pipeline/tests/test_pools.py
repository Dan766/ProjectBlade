import copy
import json

import jsonschema
import pytest

from pipeline import config, fake_llm
from pipeline.__main__ import main
from pipeline.jobs import Runner
from pipeline.stages import pools as S


@pytest.fixture(scope="module")
def real_cfg():
    return config.load_all()


@pytest.fixture
def cfg(real_cfg):
    c = copy.deepcopy(real_cfg)
    c["pipeline"]["scale"]["pilot"] = True   # tests pin the mode; the live config may be either
    return c


def distinct_lines(n: int, tag: str) -> list[str]:
    """n lines with no shared words, so no near-duplicate filtering kicks in."""
    return [f"{tag}{i} alpha{i} beta{i} gamma{i}" for i in range(n)]


def write_raw(cfg, tmp_path, edit=None):
    d = tmp_path / "raw" / "pools"
    d.mkdir(parents=True, exist_ok=True)
    for job in S.jobs(cfg):
        aid, eid = job.job_id.split("__")
        ev = cfg["events"]["events"][eid]
        data = {}
        for rel, ch in S.cells(ev):
            data.setdefault(rel, {})[ch] = distinct_lines(S.wanted(cfg, ev) + S.SPARE, f"{eid}{rel}{ch}")
        if edit:
            edit(job.job_id, data)
        jsonschema.validate(data, job.schema_inline)
        (d / f"{job.job_id}.json").write_text(json.dumps({"meta": {}, "data": data}), encoding="utf-8")
    return tmp_path / "raw", tmp_path / "validated"


# --- jobs ----------------------------------------------------------------------

def test_pilot_and_full_selection(cfg):
    jobs = S.jobs(cfg)
    assert len(jobs) == 12 and jobs[0].job_id == "griefer__beat_by_player"
    cfg["pipeline"]["scale"]["pilot"] = False
    assert len(S.jobs(cfg)) == config.summary(cfg)["s2_jobs"] == 272


def test_schema_matches_event_cells(cfg):
    ev = cfg["events"]["events"]
    s = S.schema_for(cfg, ev["beat_by_player"])
    assert set(s["properties"]) == {"hostile", "neutral", "friendly"}
    assert set(s["properties"]["hostile"]["properties"]) == {"global", "whisper", "face"}
    assert s["properties"]["hostile"]["properties"]["global"]["minItems"] == 8 + S.SPARE
    assert s["properties"]["hostile"]["properties"]["face"]["items"]["maxLength"] == 220
    amb = S.schema_for(cfg, ev["ambient_chatter"])
    assert list(amb["properties"]) == ["any"] and list(amb["properties"]["any"]["properties"]) == ["global"]
    assert set(S.schema_for(cfg, ev["fought_alongside_player"])["properties"]) == {"neutral", "friendly"}


def test_fake_llm_fits_every_event_schema(cfg):
    for eid, ev in cfg["events"]["events"].items():
        schema = S.schema_for(cfg, ev)
        jsonschema.validate(fake_llm.generate(schema, eid), schema)


def test_prompt_renders(cfg, tmp_path):
    jobs = {j.job_id: j for j in S.jobs(cfg)}
    r = Runner(None, model="fake", raw_dir=tmp_path, log=lambda m: None).render(jobs["roleplayer__ambient_chatter"])
    assert "PLAYER TYPE: Roleplayer" in r.prompt and "Ormerath" in r.prompt
    assert "- any / global: 10 lines" in r.prompt
    assert "{town} = a town name" in r.prompt and "{player}" not in r.prompt.split("Use these placeholders")[1].split("\n")[0]
    assert "[face]" not in r.prompt   # ambient is global-only: only global tone samples shown
    r2 = Runner(None, model="fake", raw_dir=tmp_path, log=lambda m: None).render(jobs["griefer__beat_by_player"])
    assert "- hostile / face: 10 lines" in r2.prompt and "[whisper]" in r2.prompt


# --- filtering -------------------------------------------------------------------

def test_filter_cell_drops_each_kind_of_bad_line():
    lines = [
        "gg {player} next time bring archers",          # ok
        "see you at {town} coward",                       # placeholder not allowed
        "lol {player ran away",                           # stray brace
        "join my discord for tips",                       # blocklisted
        "lol {player} ran from 12 looters",               # copies example
        "gg {player}, next time bring archers!!",         # near-duplicate of the first
        "{village} burns and i laugh",                    # ok? village not allowed here either
        "u call that a charge",                           # ok
    ]
    kept, dropped = S.filter_cell(lines, allowed={"player"}, examples=["lol {player} ran from 12 looters"],
                                  blocklist=["discord"])
    assert kept == ["gg {player} next time bring archers", "u call that a charge"]
    reasons = " ".join(dropped)
    for why in ("placeholder ['town']", "stray brace", "blocklisted 'discord'", "copies example", "near-duplicate",
                "placeholder ['village']"):
        assert why in reasons


# --- post ----------------------------------------------------------------------

def test_post_happy_path(cfg, tmp_path):
    res = S.post(cfg, *write_raw(cfg, tmp_path))
    assert res.errors == [] and res.warnings == []
    pool = json.loads((tmp_path / "validated" / "pools" / "griefer.json").read_text(encoding="utf-8"))
    assert set(pool) == set(cfg["pipeline"]["pilot"]["events"])
    cell = pool["beat_by_player"]["hostile"]["whisper"]
    assert len(cell) == 10 and cell[0]["id"] == "arch.griefer.beat_by_player.hostile.whisper.01"
    assert "PILOT" in res.summary[0]


def test_short_cell_is_error_with_rerun_hint(cfg, tmp_path):
    def edit(jid, data):
        if jid == "roleplayer__beat_player":
            # 10 lines, but 4 of them collapse into duplicates of one line -> 6 usable < 8 needed
            data["hostile"]["global"][1:5] = [data["hostile"]["global"][0]] * 4
    res = S.post(cfg, *write_raw(cfg, tmp_path, edit))
    assert any(e.startswith("roleplayer__beat_player hostile/global: only 6/8") and "--only roleplayer__beat_player --force" in e
               for e in res.errors), res.errors
    assert not (tmp_path / "validated" / "pools" / "roleplayer.json").exists()


def test_missing_output_is_error(cfg, tmp_path):
    raw_dir, out_dir = write_raw(cfg, tmp_path)
    (raw_dir / "pools" / "griefer__whisper_taunt.json").unlink()
    assert S.post(cfg, raw_dir, out_dir).errors == ["missing output for griefer__whisper_taunt; run `python -m pipeline run pools`"]


# --- sample CLI ------------------------------------------------------------------

def test_sample_command(cfg, tmp_path, monkeypatch, capsys):
    raw_dir, out_dir = write_raw(cfg, tmp_path)
    S.post(cfg, raw_dir, out_dir)
    monkeypatch.setattr(config, "OUT_DIR", tmp_path)
    assert main(["sample", "griefer", "whisper_taunt", "-n", "2", "--seed", "1"]) == 0
    out = capsys.readouterr().out
    assert "== griefer / whisper_taunt" in out and "-- hostile / whisper (8 lines)" in out
    assert main(["sample", "griefer", "no_event"]) == 1
    assert main(["sample", "nobody"]) == 1


def test_shape_hint(cfg):
    ev = cfg["events"]["events"]
    assert S.shape(ev["ambient_chatter"]) == '{"any": {"global": ["...", "..."]}}'
    assert S.shape(ev["encounter_greeting"]).startswith('{"hostile": {"face": ["...", "..."]}, "neutral": {"face"')
