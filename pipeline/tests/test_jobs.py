import json
import threading

import jsonschema
import pytest

from pipeline import fake_llm
from pipeline.__main__ import main
from pipeline.jobs import Job, Runner, TemplateError, render_template, select
from pipeline.llm import BudgetExceeded, CostTracker, LLMError, LLMResult

SCHEMA = {"type": "object", "properties": {"line": {"type": "string", "maxLength": 80}}, "required": ["line"]}


class FakeLLM:
    """Counts calls; can fail chosen prompts and charge a fixed cost against a budget."""

    def __init__(self, fail_if=None, cost=0.0, budget=1e9):
        self.calls = []
        self.fail_if = fail_if
        self.cost = cost
        self.tracker = CostTracker(budget)
        self._lock = threading.Lock()

    def call_json(self, prompt, schema):
        self.tracker.check()
        with self._lock:
            self.calls.append(prompt)
        if self.fail_if and self.fail_if in prompt:
            raise LLMError("attempt 1: result is not valid JSON")
        self.tracker.add(self.cost)
        return LLMResult(data=fake_llm.generate(schema, prompt), cost_usd=self.cost, attempts=1, model="fake")


@pytest.fixture
def env(tmp_path):
    prompts, schemas = tmp_path / "prompts", tmp_path / "schemas"
    prompts.mkdir()
    schemas.mkdir()
    (prompts / "a.md").write_text("<!-- version: 1 -->\nTemplate A for {{name}}, keep {player}.\n", encoding="utf-8")
    (prompts / "b.md").write_text("<!-- version: 1 -->\nTemplate B for {{name}}.\n", encoding="utf-8")
    (schemas / "line.json").write_text(json.dumps(SCHEMA), encoding="utf-8")

    def make_runner(llm, **kw):
        return Runner(llm, model="fake", prompts_dir=prompts, schemas_dir=schemas, raw_dir=tmp_path / "raw",
                      dryrun_dir=tmp_path / "dryrun", log=lambda m: None, **kw)

    jobs = [Job("s", f"a{i}", "a.md", {"name": f"n{i}"}, "line.json") for i in range(2)] + \
           [Job("s", f"b{i}", "b.md", {"name": f"n{i}"}, "line.json") for i in range(3)]
    return tmp_path, prompts, make_runner, jobs


# --- templating ----------------------------------------------------------------

def test_render_substitutes_and_keeps_game_placeholders():
    version, text = render_template("<!-- version: 3 -->\nHi {{who}} {player} {{n}}\n", {"who": "x", "n": [1]})
    assert version == "3" and text == "Hi x {player} [1]\n"


def test_render_requires_version_and_vars():
    with pytest.raises(TemplateError, match="version"):
        render_template("no header {{x}}", {"x": 1})
    with pytest.raises(TemplateError, match="missing_one"):
        render_template("<!-- version: 1 -->\n{{missing_one}}", {})


# --- acceptance: resume and prompt-edit reruns ----------------------------------

def test_first_run_writes_outputs_with_meta(env):
    tmp, _, make_runner, jobs = env
    llm = FakeLLM()
    rep = make_runner(llm, workers=3).run(jobs)
    assert (rep.ran, rep.skipped, rep.failed) == (5, 0, 0) and len(llm.calls) == 5
    out = json.loads((tmp / "raw" / "s" / "a0.json").read_text(encoding="utf-8"))
    jsonschema.validate(out["data"], SCHEMA)
    assert out["meta"]["job_id"] == "a0" and len(out["meta"]["prompt_hash"]) == 64


def test_rerun_skips_everything(env):
    _, _, make_runner, jobs = env
    make_runner(FakeLLM()).run(jobs)
    llm = FakeLLM()
    rep = make_runner(llm).run(jobs)
    assert (rep.ran, rep.skipped) == (0, 5) and llm.calls == []


def test_prompt_edit_reruns_only_affected_jobs(env):
    _, prompts, make_runner, jobs = env
    make_runner(FakeLLM()).run(jobs)
    (prompts / "a.md").write_text("<!-- version: 1 -->\nTemplate A, now edited, for {{name}}.\n", encoding="utf-8")
    llm = FakeLLM()
    rep = make_runner(llm).run(jobs)
    assert (rep.ran, rep.skipped) == (2, 3)
    assert all("now edited" in p for p in llm.calls)


def test_version_bump_alone_reruns(env):
    _, prompts, make_runner, jobs = env
    make_runner(FakeLLM()).run(jobs)
    text = (prompts / "b.md").read_text(encoding="utf-8").replace("version: 1", "version: 2")
    (prompts / "b.md").write_text(text, encoding="utf-8")
    assert make_runner(FakeLLM()).run(jobs).ran == 3


def test_changed_vars_rerun_only_that_job(env):
    _, _, make_runner, jobs = env
    make_runner(FakeLLM()).run(jobs)
    jobs[4] = Job("s", "b2", "b.md", {"name": "renamed"}, "line.json")
    llm = FakeLLM()
    assert make_runner(llm).run(jobs).ran == 1 and "renamed" in llm.calls[0]


def test_force_and_model_change_rerun(env):
    tmp, prompts, make_runner, jobs = env
    make_runner(FakeLLM()).run(jobs)
    assert make_runner(FakeLLM(), force=True).run(jobs).ran == 5
    other_model = Runner(FakeLLM(), model="haiku", prompts_dir=prompts, schemas_dir=tmp / "schemas",
                         raw_dir=tmp / "raw", log=lambda m: None)
    assert other_model.run(jobs).ran == 5


# --- failures, budget, dry run, selection --------------------------------------

def test_failure_is_logged_and_others_continue(env):
    tmp, _, make_runner, jobs = env
    rep = make_runner(FakeLLM(fail_if="Template B for n1")).run(jobs)
    assert (rep.ran, rep.failed, rep.failed_ids) == (4, 1, ["b1"])
    entry = json.loads((tmp / "raw" / "s" / "_failed.jsonl").read_text(encoding="utf-8").strip())
    assert entry["job_id"] == "b1" and "not valid JSON" in entry["error"]
    assert not (tmp / "raw" / "s" / "b1.json").exists()
    # the failed job is retried on the next run, the rest are skipped
    rep2 = make_runner(FakeLLM()).run(jobs)
    assert (rep2.ran, rep2.skipped) == (1, 4)


def test_budget_cap_stops_remaining_jobs(env):
    tmp, _, make_runner, jobs = env
    llm = FakeLLM(cost=0.6, budget=1.0)
    rep = make_runner(llm, workers=1).run(jobs)
    assert rep.ran == 2 and rep.not_run == 3 and rep.budget_stopped and rep.failed == 0
    assert rep.cost_usd == pytest.approx(1.2)
    assert not (tmp / "raw" / "s" / "_failed.jsonl").exists()


def test_dry_run_writes_prompts_only(env):
    tmp, _, make_runner, jobs = env
    llm = FakeLLM()
    make_runner(llm, dry_run=True).run(jobs)
    assert llm.calls == [] and not (tmp / "raw").exists()
    assert "keep {player}" in (tmp / "dryrun" / "s" / "a1.md").read_text(encoding="utf-8")


def test_template_error_happens_before_any_call(env):
    _, _, make_runner, jobs = env
    jobs.append(Job("s", "bad", "a.md", {}, "line.json"))
    llm = FakeLLM()
    with pytest.raises(TemplateError):
        make_runner(llm).run(jobs)
    assert llm.calls == []


def test_duplicate_and_unsafe_ids_rejected(env):
    _, _, make_runner, jobs = env
    with pytest.raises(ValueError, match="duplicate"):
        make_runner(FakeLLM()).run(jobs + [jobs[0]])
    with pytest.raises(ValueError, match="unsafe"):
        make_runner(FakeLLM()).run([Job("s", "../evil", "a.md", {"name": "x"}, "line.json")])


def test_select_only_and_limit(env):
    jobs = env[3]
    assert [j.job_id for j in select(jobs, only=["b1", "a0"])] == ["a0", "b1"]
    assert len(select(jobs, limit=2)) == 2
    with pytest.raises(ValueError, match="unknown"):
        select(jobs, only=["zzz"])


def test_many_jobs_in_parallel(env):
    tmp, _, make_runner, _ = env
    jobs = [Job("p", f"j{i:02d}", "b.md", {"name": str(i)}, "line.json") for i in range(40)]
    rep = make_runner(FakeLLM(), workers=8).run(jobs)
    assert rep.ran == 40 and len(list((tmp / "raw" / "p").glob("j*.json"))) == 40
    assert not list((tmp / "raw" / "p").glob(".*.tmp"))


# --- CLI ---------------------------------------------------------------------------

def test_cli_run_smoke_dry_run_and_unknown_stage(capsys):
    assert main(["run", "smoke", "--dry-run"]) == 0
    assert main(["run", "no_such_stage"]) == 2
    assert "available:" in capsys.readouterr().err


def test_unexpected_exception_fails_only_that_job(env):
    tmp, _, make_runner, jobs = env

    class Boom(FakeLLM):
        def call_json(self, prompt, schema):
            if "for n0" in prompt and "Template B" in prompt:
                raise PermissionError("[WinError 32] file in use")
            return super().call_json(prompt, schema)

    rep = make_runner(Boom(), workers=3).run(jobs)
    assert (rep.ran, rep.failed, rep.failed_ids) == (4, 1, ["b0"])
    assert "unexpected PermissionError" in (tmp / "raw" / "s" / "_failed.jsonl").read_text(encoding="utf-8")
