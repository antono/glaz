"""The fixtures (tests/fixtures.py) for each app's own tests,
apps/<name>/test_<name>.py; glasses.py and sandbox.py come from tests/ too.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tests"))

from fixtures import *  # noqa: E402,F401,F403
