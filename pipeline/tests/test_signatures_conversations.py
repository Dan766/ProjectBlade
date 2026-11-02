import copy
import json
from collections import Counter

import jsonschema
import pytest

from pipeline import config, fake_llm
from pipeline.jobs import Runner
from pipeline.stages import conversations as C
from pipeline.stages import signatures as SG

STYLE = {"case": "lower", "typos": "rare", "emoticons": "rare", "punctuation": "minimal", "verbosity": "short"}


@pytest.fixture(scope="module")
def real_cfg():
    return config.load_all()


@pytest.fixture
def cfg(real_cfg):
    return copy.deepcopy(real_cfg)


@pytest.fixture
def world(tmp_path, monkeypatch, real_cfg):
    """24 crafted personas (4 per faction, archetypes cycling, symmetric rival pairs) + faction names."""
    d = tmp_path / "validated"
    (d / "world").mkdir(parents=True)
    (d / "personas").mkdir()
    factions = sorted(real_cfg["world"]["factions"])
    archs = sorted(real_cfg["archetypes"])
    people = []
    for i in range(24):
        people.append({"id": f"persona_{i + 1:03d}", "username": f"user{chr(97 + i)}x{chr(97 + i)}",
                       "archetype": archs[i % len(archs)], "faction": factions[i % len(factions)],
                       "chat_style": dict(STYLE), "traits": ["sly", "loud"],
                       "backstory": "Has played since the first war.", "catchphrases": ["gg {player} again", "wow ok"],
                       "ai_weights": {}, "rivals": []})
    for i in range(0, 24, 2):
        people[i]["rivals"].append(people[i + 1]["id"])
        people[i + 1]["rivals"].append(people[i]["id"])
    (d / "personas" / "personas.json").write_text(json.dumps(people), encoding="utf-8")
    (d / "world" / "factions.json").write_text(json.dumps([{"id": f, "name": f"Realm {f}"} for f in factions]), encoding="utf-8")
    monkeypatch.setattr(SG, "VALIDATED_DIR", d)
    return people, tmp_path


def words(tag: str, n: int) -> list[str]:
    return [f"{tag}{i} alpha{i} beta{i} gamma{i}" for i in range(n)]


# --- signatures -------------------------------------------------------------------

def test_sig_events_and_schema(cfg, world):
    people, _ = world
    griefer = next(p for p in people if p["archetype"] == "griefer")
    evs = SG.sig_events(cfg, griefer)
    assert len(evs) == 11 and evs[-1] == "ambient_chatter"
    memer = next(p for p in people if p["archetype"] == "memer")
    assert SG.sig_events(cfg, memer).count("ambient_chatter") == 1     # already a memer top event
    schema = SG.schema_for(cfg, evs)
    item = schema["properties"]["captured_by_player" if "captured_by_player" in evs else evs[0]]["items"]
    assert set(item["properties"]["channel"]["enum"]) <= {"global", "whisper", "face"}
    jsonschema.validate(fake_llm.generate(schema, "x"), schema)


def test_signature_jobs_render(cfg, world, tmp_path):
    jobs = SG.jobs(cfg)
    assert len(jobs) == 24
    r = Runner(None, model="fake", raw_dir=tmp_path / "raw", log=lambda m: None).render(jobs[0])
    assert "Username: useraxa (Realm faction_01)" in r.prompt and "Has played since the first war." in r.prompt
    assert "- ambient_chatter:" in r.prompt and "placeholders: {town}" in r.prompt


def write_sig_raw(cfg, people, tmp_path, edit=None):
    d = tmp_path / "raw" / "signatures"
    d.mkdir(parents=True, exist_ok=True)
    for p in people:
        data = {}
        for eid in SG.sig_events(cfg, p):
            ev = cfg["events"]["events"][eid]
            rel = config.event_bands(ev)[0]
            data[eid] = [{"channel": ev["channels"][0], "rel": rel, "text": t} for t in words(eid + p["id"], 4)]
        if edit:
            edit(p["id"], data)
        (d / f"{p['id']}.json").write_text(json.dumps({"meta": {}, "data": data}), encoding="utf-8")
    return tmp_path / "raw", tmp_path / "validated"


def test_signatures_post_happy(cfg, world):
    people, tmp = world
    res = SG.post(cfg, *write_sig_raw(cfg, people, tmp))
    assert res.errors == []
    out = json.loads((tmp / "validated" / "signatures" / "signatures.json").read_text(encoding="utf-8"))
    first = out["persona_001"]
    assert first["username"] == "useraxa"
    eid = SG.sig_events(cfg, people[0])[0]
    assert first["signature"][eid][0]["id"] == f"sig.persona_001.{eid}.01" and len(first["signature"][eid]) == 4


def test_signatures_post_drops_and_short_is_error(cfg, world):
    people, tmp = world
    eid = SG.sig_events(cfg, people[0])[0]

    def edit(pid, data):
        if pid == "persona_001":
            data[eid][0] = {"channel": "global", "rel": data[eid][0]["rel"], "text": "x" * 150}   # too long for global
            data[eid][1]["text"] = "gg {player} again!!"                                        # copies own catchphrase
            data[eid][2]["text"] = "see u at {castle}"                                          # placeholder not allowed
    res = SG.post(cfg, *write_sig_raw(cfg, people, tmp, edit))
    joined = " ".join(res.warnings)
    assert "too long for global" in joined and "copies example 'gg {player} again'" in joined and "placeholder ['castle']" in joined
    assert any(e.startswith(f"persona_001 {eid}: only 1/2") and "--only persona_001 --force" in e for e in res.errors)


# --- conversations ------------------------------------------------------------------

def test_plan_threads(cfg, world):
    people, _ = world
    threads = C.plan_threads(cfg, people)
    assert len(threads) == 300 and threads == C.plan_threads(cfg, people)
    assert all(2 <= len(t.participants) <= 4 and len(set(t.participants)) == len(t.participants) for t in threads)
    use = Counter(pid for t in threads for pid in t.participants)
    assert set(use) == {p["id"] for p in people} and max(use.values()) - min(use.values()) <= 25
    share = sum(t.trigger != "ambient" for t in threads) / len(threads)
    assert 0.2 < share < 0.4
    by = {p["id"]: p for p in people}
    rival_threads = sum(any(b in by[a]["rivals"] for a in t.participants for b in t.participants) for t in threads)
    assert rival_threads > 100


def test_conversation_schema_and_jobs(cfg, world, tmp_path):
    people, _ = world
    jobs = C.jobs(cfg)
    assert len(jobs) == 60
    first_thread = C.plan_threads(cfg, people)[0]
    names = {p["id"]: p["username"] for p in people}
    speakers = jobs[0].schema_inline["properties"][first_thread.id]["items"]["properties"]["speaker"]["enum"]
    assert speakers == [names[pid] for pid in first_thread.participants]
    jsonschema.validate(fake_llm.generate(jobs[0].schema_inline, "x"), jobs[0].schema_inline)
    r = Runner(None, model="fake", raw_dir=tmp_path / "raw", log=lambda m: None).render(jobs[0])
    assert r.prompt.count("Participants:") == 5 and "Placeholders allowed:" in r.prompt


def write_conv_raw(cfg, people, tmp_path, edit=None):
    names = {p["id"]: p["username"] for p in people}
    d = tmp_path / "raw" / "conversations"
    d.mkdir(parents=True, exist_ok=True)
    for jid, batch in C.batches(cfg, C.plan_threads(cfg, people)).items():
        data = {t.id: [{"speaker": names[pid], "text": f"line {k} from {names[pid]}", "delay_s": 5}
                       for k, pid in enumerate(t.participants * 2)] for t in batch}
        if edit:
            edit(jid, data)
        (d / f"{jid}.json").write_text(json.dumps({"meta": {}, "data": data}), encoding="utf-8")
    return tmp_path / "raw", tmp_path / "validated"


def test_conversations_post_happy(cfg, world):
    people, tmp = world
    res = C.post(cfg, *write_conv_raw(cfg, people, tmp))
    assert res.errors == []
    out = json.loads((tmp / "validated" / "conversations" / "conversations.json").read_text(encoding="utf-8"))
    assert len(out) == 300 and out[0]["lines"][0]["delay_s"] == 0
    assert out[0]["lines"][0]["speaker"].startswith("persona_")


def test_conversations_post_errors(cfg, world):
    people, tmp = world

    def edit(jid, data):
        if jid == "conv_b01":
            t1, t2 = list(data)[:2]
            data[t1] = [ln for ln in data[t1] if ln["speaker"] == data[t1][0]["speaker"]] * 3   # others silent
            data[t2][0]["text"] = "meet at {castle} tonight"                                    # not allowed
            data[t2][1]["text"] = "{player} is everywhere lately"                               # always allowed
    res = C.post(cfg, *write_conv_raw(cfg, people, tmp, edit))
    assert any("conv_001: silent participant(s)" in e and "--only conv_b01 --force" in e for e in res.errors)
    assert any("conv_002: dropped 'meet at {castle} tonight'" in w for w in res.warnings)
    assert not any("{player} is everywhere" in w for w in res.warnings)
