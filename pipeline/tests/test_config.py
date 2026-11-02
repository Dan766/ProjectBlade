import copy

import pytest

from pipeline import config
from pipeline.__main__ import main


@pytest.fixture(scope="module")
def real_cfg():
    return config.load_all()


@pytest.fixture
def cfg(real_cfg):
    return copy.deepcopy(real_cfg)


def test_real_configs_are_consistent(real_cfg):
    assert config.check(real_cfg) == []


def test_every_event_reachable_and_archetypes_complete(real_cfg):
    assert len(real_cfg["archetypes"]) == 8
    for a in real_cfg["archetypes"].values():
        assert len(a["top_events"]) == 10
        assert set(a["examples"]) == set(config.CHANNELS)


def test_summary_sizes(real_cfg):
    s = config.summary(real_cfg)
    assert s["factions"] == 6 and s["settlements"] == 164
    assert s["s2_jobs"] == s["events"] * s["archetypes"]


def test_config_command(capsys):
    assert main(["config"]) == 0
    assert "config OK" in capsys.readouterr().out


@pytest.mark.parametrize("mutate, expected", [
    (lambda c: c["archetypes"]["griefer"]["top_events"].append("not_an_event"), "not in events.toml"),
    (lambda c: c["archetypes"]["griefer"].__setitem__("share", 0.5), "shares sum"),
    (lambda c: c["archetypes"]["trader"]["examples"]["global"].append("hi {nobody}"), "unknown placeholder"),
    (lambda c: c["archetypes"]["trader"]["examples"]["whisper"].append("x" * 141), "chars > 140"),
    (lambda c: c["archetypes"]["memer"]["examples"]["face"].append("love this bannerlord server"), "blocklisted"),
    (lambda c: c["archetypes"]["memer"]["chat_style"].__setitem__("case", "shouty"), "chat_style.case"),
    (lambda c: c["archetypes"]["memer"]["ai_weights"].__setitem__("raid", 1.5), "outside 0..1"),
    (lambda c: c["archetypes"]["memer"]["ai_weights"].pop("honor"), "keys differ"),
    (lambda c: c["events"]["events"]["peace_made"].__setitem__("channels", ["shout"]), "unknown channel"),
    (lambda c: c["events"]["events"]["peace_made"]["placeholders"].append("dragon"), "not in [placeholders]"),
    (lambda c: c["world"]["factions"]["faction_01"].__setitem__("towns", 9), "towns sum"),
    (lambda c: c["pipeline"]["pilot"]["events"].append("ghost"), "unknown event"),
])
def test_check_catches_mistakes(cfg, mutate, expected):
    mutate(cfg)
    errs = config.check(cfg)
    assert any(expected in e for e in errs), errs


def test_check_catches_bad_or_similar_banner_colors(cfg):
    cfg["world"]["factions"]["faction_02"]["colors"]["primary"] = "#1f6b6c"   # ~ faction_01 teal
    cfg["world"]["factions"]["faction_03"]["colors"]["secondary"] = "red"
    errs = " ".join(config.check(cfg))
    assert "too alike" in errs and "faction_03 colors.secondary must be #rrggbb" in errs
