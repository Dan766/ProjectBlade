import copy
import json

import pytest

from pipeline import config, report, validate
from pipeline.__main__ import main
from pipeline.stages import PostResult, Stage


@pytest.fixture(scope="module")
def real_cfg():
    return config.load_all()


@pytest.fixture
def cfg(real_cfg):
    return copy.deepcopy(real_cfg)


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture
def vdir(tmp_path):
    v = tmp_path / "validated"
    personas = [{"id": "persona_001", "username": "HelmDodger", "archetype": "griefer", "faction": "faction_01",
                 "backstory": "b", "rivals": ["persona_002"]},
                {"id": "persona_002", "username": "PuffinHearth", "archetype": "roleplayer", "faction": "faction_02",
                 "backstory": "b", "rivals": ["persona_001"]}]
    write(v / "personas" / "personas.json", personas)
    line = lambda t: [{"id": "x", "text": t}]
    write(v / "pools" / "griefer.json", {"beat_player": {"hostile": {"global": line("ez win lol") + line("he ran, {player} cried")}}})
    write(v / "pools" / "roleplayer.json", {"beat_player": {"hostile": {"global": line("ez win lol") + line("HelmDodger fled the field")}}})
    write(v / "signatures" / "signatures.json", {
        "persona_001": {"username": "HelmDodger", "signature": {"beat_player": [{"id": "s", "channel": "global", "rel": "hostile", "text": "mine now"}]}},
        "persona_002": {"username": "PuffinHearth", "signature": {"beat_player": [{"id": "s", "channel": "face", "rel": "neutral", "text": "Well met."}]}}})
    write(v / "conversations" / "conversations.json", [
        {"id": "conv_001", "trigger": "ambient", "topic": "t", "participants": ["persona_001", "persona_002"],
         "lines": [{"speaker": "persona_001", "text": "hi", "delay_s": 0}, {"speaker": "persona_002", "text": "Hail.", "delay_s": 4}]},
        {"id": "conv_002", "trigger": "ambient", "topic": "t", "participants": ["persona_001", "persona_999"], "lines": []}])
    return v


def test_cross_checks(cfg, vdir):
    res = validate.cross_checks(cfg, vdir)
    assert res.errors == ["conversation conv_002 has unknown participants ['persona_999']"]
    joined = " ".join(res.warnings)
    assert "1 line(s) assume the gender of the player or a rival" in joined and "he ran, {player} cried" in joined
    assert "1 pool line(s) name a specific player" in joined and "HelmDodger fled the field" in joined
    assert "1 line(s) appear in more than one archetype's pool" in joined and "'ez win lol'" in joined
    assert res.summary == ["cross-stage: 8 lines checked"]


def test_validate_all_skips_stages_after_an_error(cfg, vdir, tmp_path, monkeypatch):
    calls = []

    def fake(name, errors=()):
        def post(c, raw, out):
            calls.append(name)
            return PostResult(errors=list(errors), summary=[f"{name} ok"])
        return Stage(jobs=lambda c: [], post=post)
    stages = {n: fake(n) for n in validate.ORDER}
    stages["pools"] = fake("pools", errors=["pools broke"])
    monkeypatch.setattr(validate, "STAGES", stages)
    ok, results = validate.validate_all(cfg, tmp_path / "raw", vdir, tmp_path / "reports")
    assert not ok and calls == ["world", "personas", "pools"]
    assert results["signatures"] == {"skipped": "depends on pools, which has errors"}
    assert "cross" not in results
    assert json.loads((tmp_path / "reports" / "validation.json").read_text(encoding="utf-8"))["pools"]["errors"] == ["pools broke"]


def test_pool_coverage_counts_full_taxonomy(cfg, vdir):
    total, gaps = report.pool_coverage(cfg, vdir)
    assert total == config.summary(cfg)["pool_cells"] == 976
    assert "griefer/beat_player/hostile/global: 2/8" in gaps and len(gaps) == 976


def test_raw_status(tmp_path):
    write(tmp_path / "raw" / "pools" / "a.json", {"meta": {"cost_usd": 0.5}, "data": {}})
    write(tmp_path / "raw" / "pools" / "b.json", {"meta": {"cost_usd": 0.25}, "data": {}})
    (tmp_path / "raw" / "pools" / "_failed.jsonl").write_text(
        json.dumps({"job_id": "a"}) + "\n" + json.dumps({"job_id": "c"}) + "\n", encoding="utf-8")
    cost, n, open_failures = report.raw_status(tmp_path / "raw")
    assert (cost, n, open_failures) == (0.75, 2, ["pools/c"])   # a failed once but has output now


def test_sample_persona_and_conversations(vdir, tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(config, "OUT_DIR", tmp_path)
    assert main(["sample", "HelmDodger"]) == 0
    assert "[hostile/global] mine now" in capsys.readouterr().out
    assert main(["sample", "persona_002"]) == 0
    assert "[neutral/face] Well met." in capsys.readouterr().out
    assert main(["sample", "conversations", "-n", "1", "--seed", "0"]) == 0
    out = capsys.readouterr().out
    assert "== conv_00" in out
    assert main(["sample", "griefer", "beat_player"]) == 0
    assert main(["sample", "nobody_at_all"]) == 1


@pytest.mark.parametrize("line, flagged", [
    ("good call {player} {rival} is gonna cry when he sees us", True),
    ("Ser {player}, a knight who breaks his oath", True),
    ("ah {player} the one man i actually wanted to see", True),
    ("Lady {player}, ride with me", True),
    ("well played {player}. my horse says he forgives you", False),   # the horse is the referent
    ("the shepherd waved at {player}", False),                         # "he" inside a word
    ("{player} beat {troop_count} men and a goat", False),
    ("Ser {player} fought well", False),                               # ser is gender-neutral here
    ("he ran off", False),                                             # nobody unknown is gendered
])
def test_assumes_gender(line, flagged):
    from pipeline import textcheck
    assert textcheck.assumes_gender(line) is flagged
