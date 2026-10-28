"""The fixtures (fixtures.py) for the tests here."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from fixtures import *  # noqa: E402,F401,F403
