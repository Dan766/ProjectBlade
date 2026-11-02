import json
import subprocess

import jsonschema
import pytest

from pipeline import fake_llm
from pipeline.__main__ import SMOKE_SCHEMA, main
from pipeline.llm import LLM, BudgetExceeded, LLMError, parse_envelope

CFG = {
    "model": "haiku", "timeout_s": 5, "retries": 2, "per_call_budget_usd": 0.1,
    "budget_usd": 1.0, "system_prompt": "sys", "extra_args": ["--safe-mode", "--tools", ""],
}
SCHEMA = {"type": "object", "properties": {"greeting": {"type": "string"}}, "required": ["greeting"]}


def envelope(structured=None, result="", cost=0.001, is_error=False, subtype="success"):
    return json.dumps({"type": "result", "subtype": subtype, "is_error": is_error, "total_cost_usd": cost,
                       "result": result, "structured_output": structured})


class ScriptedRunner:
    """Returns queued (code, stdout, stderr) tuples and records what it was called with."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, args, stdin, cwd, timeout):
        self.calls.append({"args": args, "stdin": stdin, "cwd": cwd})
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def make_llm(runner):
    llm = LLM(cfg=dict(CFG), runner=runner, fake=False)
    llm._binary = "claude"
    return llm


# --- envelope parsing -------------------------------------------------------

def test_parse_prefers_structured_output():
    data, cost = parse_envelope(envelope(structured={"greeting": "hail"}, result="ignored", cost=0.002))
    assert data == {"greeting": "hail"} and cost == 0.002


def test_parse_falls_back_to_fenced_result():
    data, _ = parse_envelope(envelope(result='```json\n{"greeting": "hail"}\n```'))
    assert data == {"greeting": "hail"}


def test_parse_rejects_error_envelope():
    with pytest.raises(ValueError, match="CLI reported error"):
        parse_envelope(envelope(is_error=True, subtype="error_max_budget_usd"))


def test_parse_rejects_non_json_stdout():
    with pytest.raises(ValueError, match="not JSON"):
        parse_envelope("Error: not logged in")


# --- call_json ---------------------------------------------------------------

def test_success_first_try_tracks_cost():
    runner = ScriptedRunner((0, envelope(structured={"greeting": "hail"}, cost=0.003), ""))
    llm = make_llm(runner)
    res = llm.call_json("say hi", SCHEMA)
    assert res.data == {"greeting": "hail"} and res.attempts == 1
    assert llm.tracker.spent_usd == pytest.approx(0.003)


def test_args_isolation_and_prompt_on_stdin():
    runner = ScriptedRunner((0, envelope(structured={"greeting": "hail"}), ""))
    make_llm(runner).call_json("the prompt", SCHEMA)
    call = runner.calls[0]
    assert call["stdin"].startswith("the prompt\n")
    assert "JSON Schema" in call["stdin"] and '"greeting"' in call["stdin"]
    assert "the prompt" not in call["args"]
    for flag in ["-p", "--safe-mode", "--json-schema", "--system-prompt", "--max-budget-usd"]:
        assert flag in call["args"]
    assert call["args"][call["args"].index("--model") + 1] == "haiku"
    assert call["args"][call["args"].index("--tools") + 1] == ""


def test_schema_violation_retries_with_feedback():
    runner = ScriptedRunner(
        (0, envelope(structured={"wrong": 1}), ""),
        (0, envelope(structured={"greeting": "hail"}), ""),
    )
    res = make_llm(runner).call_json("say hi", SCHEMA)
    assert res.attempts == 2
    assert "previous output failed" in runner.calls[1]["stdin"]
    assert "greeting" in runner.calls[1]["stdin"]


def test_timeout_and_crash_then_success():
    runner = ScriptedRunner(
        subprocess.TimeoutExpired("claude", 5),
        (1, "", "boom"),
        (0, envelope(structured={"greeting": "hail"}), ""),
    )
    assert make_llm(runner).call_json("x", SCHEMA).attempts == 3


def test_gives_up_after_retries():
    runner = ScriptedRunner(*[(0, envelope(result="not json"), "")] * 3)
    with pytest.raises(LLMError, match="attempt 3"):
        make_llm(runner).call_json("x", SCHEMA)
    assert len(runner.calls) == 3


def test_budget_cap_stops_calls():
    runner = ScriptedRunner(*[(0, envelope(structured={"greeting": "hi"}, cost=0.6), "")] * 3)
    llm = make_llm(runner)
    llm.call_json("a", SCHEMA)
    llm.call_json("b", SCHEMA)  # spent 1.2 after this
    with pytest.raises(BudgetExceeded):
        llm.call_json("c", SCHEMA)
    assert len(runner.calls) == 2


# --- fake LLM and smoke -----------------------------------------------------

def test_fake_llm_is_deterministic_and_valid():
    schema = {"type": "object", "properties": {
        "names": {"type": "array", "items": {"type": "string", "maxLength": 10}, "minItems": 3},
        "tier": {"type": "integer", "minimum": 1, "maximum": 3},
        "kind": {"enum": ["infantry", "archer", "cavalry"]},
    }}
    a, b = fake_llm.generate(schema, "seed"), fake_llm.generate(schema, "seed")
    assert a == b
    jsonschema.validate(a, schema)
    assert fake_llm.generate(schema, "other") != a


def test_smoke_command_with_fake_llm(monkeypatch, capsys):
    monkeypatch.setenv("PIPELINE_FAKE_LLM", "1")
    assert main(["smoke"]) == 0
    out = capsys.readouterr().out
    payload = json.loads(out[: out.rindex("}") + 1])
    jsonschema.validate(payload, SMOKE_SCHEMA)
    assert "cost_usd=" in out


def test_json_error_feedback_explains_double_quotes():
    runner = ScriptedRunner(
        (0, envelope(result='{"greeting": "he said "hi" to me"}'), ""),
        (0, envelope(structured={"greeting": "he said 'hi' to me"}), ""),
    )
    make_llm(runner).call_json("x", SCHEMA)
    assert "never use the double-quote character" in runner.calls[0]["stdin"]
    assert "close each object with }" in runner.calls[1]["stdin"]
