"""Fixtures for glaz on emulated glasses (glasses.py, docs/TESTING.md),
for the tests here and each app's own (apps/<name>/test_<name>.py): both
conftest.py take them.

    frame, halo   glaz started on that pair of glasses, the phone's clock set
    glasses       the same test on each pair of glasses that has the module
                  named by @pytest.mark.module('name'), or on both

@pytest.mark.heap(kb) gives emulated Frame kb more Lua heap than HEAP, for
a test the emulator's bigger code runs out where Frame does not
(docs/TESTING.md, "Memory"); the reason goes next to it.
"""
import pytest

from glasses import Glasses, has_module


def started(device, tmp_path, request=None):
    g = Glasses(device, tmp_path / device)
    mark = request and request.node.get_closest_marker("heap")
    if mark and device == "frame":
        g.emu.heap += mark.args[0] * 1024
    g.start()
    g.set_clock()
    return g


@pytest.fixture
def frame(tmp_path, request):
    g = started("frame", tmp_path, request)
    yield g
    g.stop()


@pytest.fixture
def halo(tmp_path, request):
    g = started("halo", tmp_path, request)
    yield g
    g.stop()


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "module(name): the module under test; `glasses` runs "
        "on each pair of glasses it goes to")
    config.addinivalue_line(
        "markers", "heap(kb): kb more Lua heap on emulated Frame, for code "
        "the emulator holds bigger than Frame does")


def pytest_generate_tests(metafunc):
    if "glasses" not in metafunc.fixturenames:
        return
    mark = metafunc.definition.get_closest_marker("module")
    devices = ["frame", "halo"]
    if mark:
        devices = [d for d in devices if has_module(d, mark.args[0])]
    metafunc.parametrize("device", devices)


@pytest.fixture
def glasses(device, tmp_path, request):
    g = started(device, tmp_path, request)
    yield g
    g.stop()
