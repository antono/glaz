"""pytest plugin: line coverage of the Lua the emulated glasses run
(docs/TESTING.md, "Which Lua the tests reach").

    LUACOV=cov.json PYTHONPATH=tests pytest -p lua_coverage tests apps
    python scripts/lua_coverage.py cov.json [frame|halo] [--lines] [file...]

A line hook in each emulator's Lua state records every (source, line) that
runs; at the end of the session they go to the file LUACOV names, as
{device: {source: [lines]}}. Without LUACOV the plugin does nothing.

The hook allocates on every line, so Frame's heap limit is lifted while it
runs: the tests that live on that limit (test_frame_emulator.py, the
"let go of packet by packet" ones) fail under it, which is not a finding.
Run the suite in parts and give scripts/lua_coverage.py several files to
merge them: coverage under the hook is slow.
"""
import json
import os
from pathlib import Path

HOOK = r"""
local cov = ...
local getinfo = debug.getinfo
debug.sethook(function(_, line)
  local i = getinfo(2, 'S')
  if i then cov(i.source, line) end
end, 'l')
"""

hits = {"frame": {}, "halo": {}}


def recorder(device):
    seen = hits[device]

    def cov(source, line):
        seen.setdefault(source, set()).add(int(line))
    return cov


def pytest_configure(config):
    if not os.environ.get("LUACOV"):
        return
    import frame_emulator

    orig = frame_emulator.FrameEmulator._build

    def build(self):
        self.heap = None
        orig(self)
        self._lua.execute(HOOK, recorder("frame"))
    frame_emulator.FrameEmulator._build = build

    from halo_emulator import emulator as hemu
    horig = hemu.HaloEmulator._build_runtime

    def hbuild(self):
        horig(self)
        self._lua.execute(HOOK, recorder("halo"))
    hemu.HaloEmulator._build_runtime = hbuild


def pytest_sessionfinish(session, exitstatus):
    out = os.environ.get("LUACOV")
    if out:
        Path(out).write_text(json.dumps(
            {d: {s: sorted(l) for s, l in srcs.items()}
             for d, srcs in hits.items()}))
