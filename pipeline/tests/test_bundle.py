import json

import pytest

from pipeline import bundle, config


@pytest.fixture(scope="module")
def cfg():
    return config.load_all()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


STYLE = {"case": "lower", "typos": "rare", "emoticons": "rare", "punctuation": "minimal", "verbosity": "short"}


@pytest.fixture
def validated(tmp_path, cfg):
    v = tmp_path / "validated"
    write(v / "world" / "factions.json", [{"id": f, "name": f"Realm {f}"} for f in sorted(cfg["world"]["factions"])])
    write(v / "world" / "settlements.json", [{"id": "town_01_01", "faction": "faction_01", "type": "town", "name": "Calvenza", "blurb": "b"}])
    people = [{"id": f"persona_00{i}", "username": f"user_{i}", "archetype": "griefer", "faction": "faction_01",
               "chat_style": STYLE, "traits": ["a"], "backstory": "b", "catchphrases": ["c"],
               "ai_weights": {"raid": 0.5}, "rivals": [f"persona_00{3 - i}"]} for i in (1, 2)]
    write(v / "personas" / "personas.json", people)
    for aid in cfg["archetypes"]:
        pool = {}
        for eid, ev in cfg["events"]["events"].items():
            for rel in config.event_bands(ev):
                for ch in ev["channels"]:
                    pool.setdefault(eid, {}).setdefault(rel, {})[ch] = [{"id": f"arch.{aid}.{eid}.{rel}.{ch}.01", "text": "gg {player}"}]
        write(v / "pools" / f"{aid}.json", pool)
    write(v / "signatures" / "signatures.json", {p["id"]: {"username": p["username"], "signature": {
        "beat_player": [{"id": "sig.x", "channel": "global", "rel": "hostile", "text": "mine now"}]}} for p in people})
    write(v / "conversations" / "conversations.json", [{"id": "conv_001", "trigger": "ambient", "topic": "t",
        "participants": ["persona_001", "persona_002"], "lines": [
            {"speaker": "persona_001", "text": "hi", "delay_s": 0}, {"speaker": "persona_002", "text": "yo", "delay_s": 3},
            {"speaker": "persona_001", "text": "bye", "delay_s": 5}]}])
    return v


def test_build_and_check(cfg, validated, tmp_path):
    dest = tmp_path / "out"
    manifest = bundle.build(cfg, validated, dest)
    assert bundle.check(dest, cfg) == []
    assert manifest["continent"] == "Ormerath" and manifest["counts"]["personas"] == 2
    assert manifest["counts"]["pool_lines"] == 976 and manifest["counts"]["conversations"] == 1
    assert "dialogue/personas/persona_001.json" in manifest["files"] and "events.json" in manifest["files"]
    ev = json.loads((dest / "events.json").read_text(encoding="utf-8"))
    assert ev["events"]["ambient_chatter"]["relationships"] == ["any"] and "player" in ev["placeholders"]


def test_check_catches_contract_breaks(cfg, validated, tmp_path):
    dest = tmp_path / "out"
    bundle.build(cfg, validated, dest)
    (dest / "dialogue" / "personas" / "persona_002.json").unlink()
    convs = json.loads((dest / "dialogue" / "conversations.json").read_text(encoding="utf-8"))
    convs[0]["lines"][1]["speaker"] = "persona_777"
    (dest / "dialogue" / "conversations.json").write_text(json.dumps(convs), encoding="utf-8")
    people = json.loads((dest / "personas.json").read_text(encoding="utf-8"))
    people[0]["username"] = "has spaces!"
    (dest / "personas.json").write_text(json.dumps(people), encoding="utf-8")
    errs = " | ".join(bundle.check(dest, cfg))
    for expected in ("dialogue/personas/persona_002.json: missing or hash mismatch", "persona persona_002: no dialogue/personas file",
                     "conversation conv_001: participant/speaker", "personas.json persona_001", "personas.json: missing or hash mismatch"):
        assert expected in errs, errs


def test_bundle_swaps_atomically_and_keeps_live_on_failure(cfg, validated, tmp_path):
    game = tmp_path / "game_data"
    (game / "layout.json").parent.mkdir(parents=True)
    (game / "layout.json").write_text("{}", encoding="utf-8")          # hand-authored file: never touched
    _, errs = bundle.bundle(cfg, validated, game)
    assert errs == [] and (game / "generated" / "manifest.json").exists() and not (game / "generated.tmp").exists()
    first = (game / "generated" / "manifest.json").read_text(encoding="utf-8")

    write(validated / "conversations" / "conversations.json", [{"id": "bad"}])   # breaks the contract
    _, errs = bundle.bundle(cfg, validated, game)
    assert errs and (game / "generated.tmp").exists()
    assert (game / "generated" / "manifest.json").read_text(encoding="utf-8") == first   # live bundle untouched
    assert (game / "layout.json").read_text(encoding="utf-8") == "{}"
