"""Tier 8: soundgraph patches, compiled and verified on the Axoloti.

The full product pipeline: patch JSON -> sgaxo codegen -> arm-none-eabi-g++
against the stock firmware -> upload -> render on the board -> read the raw
float32 samples back over USB -> compare against the SAME golden vectors the
native, WASM and ESP32 targets answer to. If these pass, the Axoloti is a
verified soundgraph target for the declared node subset, not a "compatible-ish"
one.
"""

import pathlib
import shutil
import struct
import sys
import time

import pytest

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "sgaxo"))

import codegen  # noqa: E402

GOLDEN = _HERE.parent.parent.parent / "tests" / "golden"

SGX_SHM = 0x2001C000
SGX_CAPTURE = 0xC0400000
OFF_FRAMES_DONE = 8
OFF_STATUS = 20

# Native golden agreement is loose only where libm is involved; these kernels
# share the committed sine table with dsp-core, so the bar sits at WASM level.
TOLERANCE = 1e-5


def read_golden_wav(path):
    """Minimal RIFF reader for the float32 golden vectors (format 3)."""
    data = path.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", path
    pos, fmt, payload = 12, None, None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", body, 0)
        elif cid == b"data":
            payload = body
        pos += 8 + size + (size & 1)
    assert fmt is not None and payload is not None, path
    wformat, channels, rate, _bps, _align, bits = fmt
    assert (wformat, channels, rate, bits) == (3, 1, 48000, 32), fmt
    return list(struct.unpack(f"<{len(payload) // 4}f", payload))


@pytest.fixture(scope="module")
def toolchain():
    if shutil.which(codegen.CXX) is None:
        pytest.skip("arm-none-eabi toolchain not installed")
    if not (codegen.SDK / "axoloti.elf").exists():
        pytest.skip("sdk not fetched (tools/fetch-sdk.sh)")


def run_case(board, case_name, patch_rel, frames, events=(), patch_path=None):
    path = patch_path if patch_path is not None else GOLDEN / patch_rel
    binary, pid, buffers = codegen.build_patch(path, frames=frames,
                                               name=case_name, events=events)
    board.stop_patch()
    for addr, blob in buffers:
        board.write_mem(addr, blob)
        assert board.read_mem(addr, len(blob)) == blob, "buffer upload corrupt"
    board.run_patch(binary, expect_patch_id=pid)
    deadline = time.monotonic() + 3.0 + frames / 48000.0
    while board.read_u32(SGX_SHM + OFF_STATUS) != 1:
        if time.monotonic() > deadline:
            pytest.fail(f"{case_name}: capture never completed "
                        f"({board.read_u32(SGX_SHM + OFF_FRAMES_DONE)}/{frames})")
        time.sleep(0.05)
    raw = board.read_mem(SGX_CAPTURE, frames * 4)
    board.stop_patch()
    return list(struct.unpack(f"<{frames}f", raw))


def compare(rendered, golden, case_name, tolerance=TOLERANCE):
    assert len(rendered) == len(golden)
    worst, worst_i = 0.0, -1
    for i, (a, b) in enumerate(zip(rendered, golden)):
        d = abs(a - b)
        if d > worst:
            worst, worst_i = d, i
    print(f"\n{case_name}: {len(golden)} frames, max abs error {worst:.3g}"
          f"{f' at frame {worst_i}' if worst_i >= 0 else ''}")
    assert worst < tolerance, (
        f"{case_name}: board output diverges from the golden vector by "
        f"{worst:.3g} at frame {worst_i} (limit {tolerance})")
    return worst


def test_sine_golden_on_hardware(board, toolchain):
    """The first soundgraph patch compiled from JSON and verified on the
    Axoloti against the shared golden manifest."""
    golden = read_golden_wav(GOLDEN / "vectors" / "sine.wav")
    rendered = run_case(board, "sine", "cases/sine.json", len(golden))
    compare(rendered, golden, "sine")


@pytest.mark.parametrize("case,frames_hint", [
    ("saw", None),            # polyBLEP: exact arithmetic
    ("noise", None),          # Xorshift + float scale: exact arithmetic
    ("noise-pink", None),     # Kellet pink filter: exact arithmetic
    ("square", None),         # polyBLEP: exact arithmetic
    ("lfo", None),            # triangle shape: exact arithmetic
    ("adsr", None),           # codegen-baked exp coefficients
    ("delay-feedback", None), # noise -> gain -> SDRAM delay line, no libm
    ("ahd-envelope", None),   # Retrigger clock -> AHD: exact arithmetic
    ("arpeggio", None),       # codegen-baked pow(2, interval/12)
])
def test_golden_case_on_hardware(board, toolchain, case, frames_hint):
    golden = read_golden_wav(GOLDEN / "vectors" / f"{case}.wav")
    rendered = run_case(board, case, f"cases/{case}.json", len(golden))
    compare(rendered, golden, case)


def test_first_synth_golden_on_hardware(board, toolchain):
    """The flagship example — note input, saw, LFO-modulated filter, ADSR,
    gain, soft-limited output — compiled from JSON and verified against the
    golden vector, note events replayed on block boundaries exactly like the
    native runner. The SVF's per-block tan/exp2 run as on-board polynomials,
    so this case carries the cross-target tolerance (native vs ESP32 is 1e-4)
    rather than the sine case's bit-exact bar."""
    golden = read_golden_wav(GOLDEN / "vectors" / "first-synth.wav")
    events = [(0, True, 45, 0.9), (12000, False, 45, 0.0)]
    rendered = run_case(board, "first-synth",
                        "../../examples/patches/first-synth.json",
                        len(golden), events=events)
    compare(rendered, golden, "first-synth", tolerance=1e-4)


def test_first_synth_playable_over_midi(board, toolchain):
    """The compiled patch is an instrument: play a note over USB MIDI and the
    board must sound. Re-arms the capture buffer to observe the audio."""
    mido = pytest.importorskip("mido")
    name = next((n for n in mido.get_output_names() if "axoloti" in n.lower()),
                None)
    if name is None:
        pytest.skip("no CoreMIDI port for the board")
    binary, pid, _buffers = codegen.build_patch(
        GOLDEN / "../../examples/patches/first-synth.json",
        frames=4800, name="first-synth-live")
    board.run_patch(binary, expect_patch_id=pid)
    # Let the (event-free) capture finish rendering silence, then re-arm it
    # and play. The recapture then contains the note.
    deadline = time.monotonic() + 3.0
    while board.read_u32(SGX_SHM + OFF_STATUS) != 1:
        assert time.monotonic() < deadline
        time.sleep(0.05)
    port = mido.open_output(name)
    try:
        board.write_mem(SGX_SHM + OFF_FRAMES_DONE, struct.pack("<I", 0))
        board.write_mem(SGX_SHM + OFF_STATUS, struct.pack("<I", 0))
        port.send(mido.Message("note_on", note=57, velocity=100))
        deadline = time.monotonic() + 3.0
        while board.read_u32(SGX_SHM + OFF_STATUS) != 1:
            assert time.monotonic() < deadline, "recapture never completed"
            time.sleep(0.05)
        port.send(mido.Message("note_off", note=57))
    finally:
        port.close()
    raw = board.read_mem(SGX_CAPTURE, 4800 * 4)
    board.stop_patch()
    samples = struct.unpack("<4800f", raw)
    peak = max(abs(s) for s in samples)
    print(f"\nlive MIDI note through the compiled patch: peak {peak:.3f}")
    assert peak > 0.05, "MIDI note produced no audio"


SG_RENDER = GOLDEN.parent.parent / "build" / "bin" / "sg-render"


def _native_reference(fixture, wav, seconds=0.1, notes=None, gate=0.7,
                      velocity=0.9):
    """Golden-on-demand: sg-render renders the fixture (silently, or playing
    `notes` spread evenly, exactly its scheduler); the board must match the
    left channel sample for sample."""
    if not SG_RENDER.exists():
        pytest.skip("native sg-render not built (build/bin/sg-render)")
    import subprocess
    cmd = [str(SG_RENDER), str(fixture), str(wav), "--seconds", str(seconds),
           "--float", "--quiet", "--gate", str(gate),
           "--velocity", str(velocity)]
    if notes:
        cmd += ["--notes", ",".join(str(n) for n in notes)]
    else:
        cmd += ["--silent"]
    subprocess.run(cmd, check=True)
    # sg-render writes stereo float32; the board capture is the left channel.
    data = wav.read_bytes()
    pos, payload = 12, None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        if cid == b"data":
            payload = data[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)
    stereo = struct.unpack(f"<{len(payload) // 4}f", payload)
    return list(stereo[0::2])


@pytest.mark.parametrize("fixture_name,tolerance", [
    ("maths-mix", TOLERANCE),       # pure arithmetic; ~1 ULP fma residue
    ("effects-chain", TOLERANCE),   # measured 4.2e-7: tanh/exp ride exp2f_approx
    ("comb-room", TOLERANCE),       # Crush/Comb/Allpass: exact arithmetic
])
def test_fixture_matches_native_render(board, toolchain, tmp_path,
                                       fixture_name, tolerance):
    fixture = _HERE / "fixtures" / f"{fixture_name}.json"
    golden = _native_reference(fixture, tmp_path / "native.wav")
    rendered = run_case(board, fixture_name, None, len(golden),
                        patch_path=fixture)
    compare(rendered, golden, fixture_name, tolerance=tolerance)


@pytest.mark.parametrize("case,tolerance", [
    # Slide's per-sample pow(2,x) runs through exp2f_approx; a downstream
    # oscillator integrates the tiny frequency error into coherent phase
    # drift. Measured 9e-6 with the degree-8 polynomial (the first, worse
    # polynomial produced 5e-3 here — this case is the exp2 accuracy meter).
    ("slide", 5e-5),
    ("noise-oscillator", 5e-5),
])
def test_slide_family_golden_on_hardware(board, toolchain, case, tolerance):
    golden = read_golden_wav(GOLDEN / "vectors" / f"{case}.wav")
    rendered = run_case(board, case, f"cases/{case}.json", len(golden))
    compare(rendered, golden, case, tolerance=tolerance)


def _mirror_schedule(total_frames, notes, gate=0.7, velocity=0.9):
    """sg-render's build_note_schedule, verbatim."""
    if not notes:
        return []
    slot = total_frames // len(notes)
    held = int(slot * gate)
    events = []
    for i, note in enumerate(notes):
        events.append((i * slot, True, note, velocity))
        events.append((i * slot + held, False, note, 0.0))
    return sorted(events, key=lambda e: e[0])


@pytest.mark.parametrize("rel,notes,seconds,tolerance", [
    # Module expansion: the amp module unfolds into ADSR + Gain + Level seams.
    # 5e-4: note 60's frequency is an inexact exp2 lattice point, and the
    # saw's polyBLEP edges amplify the integrated phase drift (slide physics).
    ("examples/patches/envelope-amp.json", [48, 55, 60], 0.5, 5e-4),
    # Modules + Comb (Karplus-Strong pitch tracking) + Noise burst.
    ("examples/patches/plucked-string.json", [45, 52, 57], 0.5, 5e-5),
    # AudioInput + a feedback edge through the Delay. Rendered with silent
    # input on both sides, so this proves the wiring runs clean (no NaN, no
    # garbage) rather than exercising audio content.
    ("examples/patches/delay-echo.json", None, 0.25, TOLERANCE),
    # Sampler: the buffer ships to SDRAM over USB, the read head runs in
    # libgcc soft-double, and the notes trigger it through NoteInput.trigger.
    ("examples/patches/nodes/Sampler.json", [60, 64], 0.6, TOLERANCE),
])
def test_editor_patch_matches_native_render(board, toolchain, tmp_path, rel,
                                            notes, seconds, tolerance):
    """Real editor patches — seams, modules, feedback and all — compiled
    through patch-io's resolver and verified against the native render."""
    patch = GOLDEN.parent.parent / rel
    golden = _native_reference(patch, tmp_path / "native.wav",
                               seconds=seconds, notes=notes)
    events = _mirror_schedule(len(golden), notes or [])
    rendered = run_case(board, pathlib.Path(rel).stem, None, len(golden),
                        events=events, patch_path=patch)
    compare(rendered, golden, pathlib.Path(rel).stem, tolerance=tolerance)


def test_unsupported_patch_is_refused(toolchain):
    """The subset gate must refuse, by name, what the target cannot run."""
    # A natively valid editor patch whose node type sgaxo does not carry:
    # the refusal must come from the subset gate, by name.
    compressor = (GOLDEN.parent.parent / "examples" / "patches" / "nodes"
                  / "Compressor.json")
    with pytest.raises(codegen.Unsupported, match="not in the Axoloti subset"):
        codegen.build_patch(compressor, name="refused")
