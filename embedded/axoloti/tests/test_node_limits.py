"""How many soundgraph-style nodes fit, as opposed to raw oscillators?

The nodelab patch runs faithful ports of dsp-core node inner loops (float
math, per-block indirect dispatch, per-node buffers, summing mix pass) with
dsp-core's actual committed sine table. Two sweeps: standalone Sine nodes,
and full Sine->SVF->Gain voices. Same tri-signal overload detection as the
raw-oscillator ramp, results in tests/reports/node_limits.json.
"""

import json

import pytest

import ramp
import shm
from axoproto import ProtocolError
from conftest import load_patch_bin
from test_limits import REPORT_DIR


@pytest.fixture(scope="module")
def nodelab(board):
    board.run_patch(load_patch_bin("nodelab"), expect_patch_id=shm.NODELAB_ID)
    shm.set_tone(board, True)
    yield board
    try:
        shm.set_nsine(board, 0)
        shm.set_nvoice(board, 0)
        shm.set_tone(board, False)
        board.stop_patch()
    except ProtocolError:
        pass


def _report(key, baseline, last_clean, first_dirty, results):
    REPORT_DIR.mkdir(exist_ok=True)
    path = REPORT_DIR / "node_limits.json"
    report = json.loads(path.read_text()) if path.exists() else {}
    report[key] = {"max_clean": last_clean,
                   "first_overload": first_dirty,
                   "baseline": baseline,
                   "sweep": results}
    path.write_text(json.dumps(report, indent=2))


def test_sine_node_limit(nodelab):
    board = nodelab
    baseline, last_clean, first_dirty, results = ramp.run_ramp(
        board, shm.set_nsine,
        steps=(8, 16, 24, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
               288, 320),
        refine_to=4)
    _report("sine_nodes", baseline, last_clean, first_dirty, results)
    ramp.print_table(results, label="sines")
    if first_dirty is None:
        print("  no overload up to the 320-node pool")
    print(f"  => clean limit: {last_clean} soundgraph Sine nodes")
    assert baseline["dsp_load_pct"] < 20
    assert last_clean >= 8, "Sine nodes overload implausibly early"


def test_voice_limit(nodelab):
    board = nodelab
    baseline, last_clean, first_dirty, results = ramp.run_ramp(
        board, shm.set_nvoice,
        steps=(4, 8, 12, 16, 24, 32, 40, 48, 56, 64, 80, 96),
        refine_to=2)
    _report("voices", baseline, last_clean, first_dirty, results)
    ramp.print_table(results, label="voices")
    if first_dirty is None:
        print("  no overload up to the 96-voice pool")
    print(f"  => clean limit: {last_clean} Sine->SVF->Gain voices "
          f"({last_clean * 3} nodes)")
    assert baseline["dsp_load_pct"] < 20
    assert last_clean >= 4, "voices overload implausibly early"
