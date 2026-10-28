"""Fixtures for glaz on emulated glasses (glasses.py, docs/TESTING.md),
for the tests here and each app's own (apps/<name>/test_<name>.py): both
conftest.py take them.

    frame, halo   glaz started on that pair of glasses, the phone's clock set
    glasses       the same test on each pair of glasses that has the module
                  named by @pytest.mark.module('name'), or on both
"""
import pytest

from glasses import Glasses, has_module


def started(device, tmp_path):
    g = Glasses(device, tmp_path / device)
    g.start()
    g.set_clock()
    return g


@pytest.fixture
def frame(tmp_path):
    g = started("frame", tmp_path)
    yield g
    g.stop()


@pytest.fixture
def halo(tmp_path):
    g = started("halo", tmp_path)
    yield g
    g.stop()


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "module(name): the module under test; `glasses` runs "
        "on each pair of glasses it goes to")


def pytest_generate_tests(metafunc):
    if "glasses" not in metafunc.fixturenames:
        return
    mark = metafunc.definition.get_closest_marker("module")
    devices = ["frame", "halo"]
    if mark:
        devices = [d for d in devices if has_module(d, mark.args[0])]
    metafunc.parametrize("device", devices)


@pytest.fixture
def glasses(device, tmp_path):
    g = started(device, tmp_path)
    yield g
    g.stop()
