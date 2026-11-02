import pytest

from pipeline import bundle, config
from pipeline.stages import personas, signatures


@pytest.fixture(autouse=True)
def _isolate_outputs(tmp_path_factory, monkeypatch):
    """No test may read or write the real pipeline/out or game/data (a CLI test once ran `validate`
    against live data mid-run). Tests that need data monkeypatch these again to their own dirs."""
    sandbox = tmp_path_factory.mktemp("sandbox")
    monkeypatch.setattr(config, "OUT_DIR", sandbox / "out")
    monkeypatch.setattr(bundle, "GAME_DATA_DIR", sandbox / "game_data")
    monkeypatch.setattr(personas, "VALIDATED_DIR", sandbox / "out" / "validated")
    monkeypatch.setattr(signatures, "VALIDATED_DIR", sandbox / "out" / "validated")
