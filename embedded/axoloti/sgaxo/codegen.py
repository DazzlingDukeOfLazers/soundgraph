"""sgaxo: compile a soundgraph patch (JSON) into an Axoloti patch binary.

The soundgraph workflow the Axoloti audience already knows: a program on the
computer turns the patch into code, compiles it, and programs the board.

sgaxo is a BACKEND. The front-end is patch-io, reached through
`sg-validate --resolve`: it loads any schema version, expands modules,
resolves Input/Output seams into terminals, validates (including that every
multi-connection lands on a summing input), and emits the flattened graph
plus the engine's own schedule — execution order and feedback edges — so
scheduling stays defined in exactly one place. sgaxo consumes that contract
and generates C++ over the kernel library; it never re-derives an order and
never re-validates what the native validator already ruled on.

Node types outside the declared subset (SUPPORTED below) are refused with a
message that names the node and the reason — never silently degraded.

Fidelity rules:
- The generated graph runs at dsp-core's 64-frame block size (kernels.h).
- Every coefficient derived only from parameters (ADSR exp() curves, glide,
  Arpeggio's interval ratio, Crush's level count) is computed HERE, in double
  precision with float32-emulated intermediate steps, and baked as a literal.
- Summing inputs premix in connection order; feedback edges read a snapshot
  buffer summed at block end — both exactly as graph.cpp does it.

Usage as a library (the tests do this):
    from codegen import build_patch
    binary, patch_id = build_patch(path, frames=24000,
                                   events=[(0, True, 45, 0.9)])
"""

import json
import math
import pathlib
import struct
import subprocess
import zlib

HERE = pathlib.Path(__file__).resolve().parent
RIG = HERE.parent
BUILD = HERE / "build"
SDK = RIG / "sdk"
REPO = RIG.parent.parent
DSP_CORE_SRC = REPO / "dsp-core" / "src"
SG_VALIDATE = REPO / "build" / "bin" / "sg-validate"

# SDRAM map: 0xC0000000 +4MB kernel delay lines (.sdram section);
# 0xC0400000 capture; 0xC0480000 +3.5MB sample buffers, host-uploaded.
BUFFER_POOL_BASE = 0xC0480000
BUFFER_POOL_SIZE = 0x380000

SAMPLE_RATE = 48000.0
FWID = "0xe95bac96"

CXX = "arm-none-eabi-g++"
OBJCOPY = "arm-none-eabi-objcopy"
NM = "arm-none-eabi-nm"

CXXFLAGS = [
    "-nostdlib", "-ffreestanding", "-fno-exceptions", "-fno-rtti",
    "-mcpu=cortex-m4", "-O3", "-fomit-frame-pointer", "-falign-functions=16",
    "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16", "-mthumb", "-std=c++17",
    "-fno-math-errno", "-fno-threadsafe-statics", "-fno-use-cxa-atexit",
    "-fno-reorder-functions",
    # No fused multiply-add: the golden vectors were rendered with separate
    # rounding steps, and bit-fidelity is the product claim.
    "-ffp-contract=off",
    "-Wall", "-Wextra",
    f"-DSG_EXPECTED_FWID={FWID}",
]


class Unsupported(Exception):
    """A patch that this target cannot honestly run."""


def f32(x):
    """Round a python float to the nearest float32, like a C float assignment."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def _exp_coeff(seconds):
    """AdsrNode::coefficient_for / NoteInput glide, float32 step for step."""
    samples = f32(f32(seconds) * SAMPLE_RATE)
    if samples < 1.0:
        return 0.0
    return f32(math.exp(f32(f32(-6.907755) / samples)))


def _attack_step(seconds):
    samples = f32(f32(seconds) * SAMPLE_RATE)
    return 1.0 if samples < 1.0 else f32(1.0 / samples)


def _lit(x):
    """A float literal that round-trips exactly to the intended float32."""
    return f"{f32(x)!r}f"


# The declared subset, keyed by dsp-core type names (the resolver has already
# turned seams into terminals). inputs: kernel argument order; connectable:
# which may carry wires on this target; fixed: parameter values this target
# requires; defaults mirror the node descriptors.
SUPPORTED = {
    "NoteInput": {
        "inputs": [], "connectable": set(),
        "params": {"glide": 0.0, "transpose": 0.0, "voices": 1.0},
        "fixed": {"voices": 1.0},
        "outputs": ["frequency", "gate", "velocity", "trigger"],
    },
    "AudioInput": {
        "inputs": [], "connectable": set(),
        "params": {"gain": 1.0},
        "fixed": {},
        "outputs": ["left", "right"],
    },
    "SineOscillator": {
        "inputs": ["frequency", "fm", "pm", "feedback"],
        "connectable": {"frequency"},
        "params": {"frequency": 440.0, "shape": 0.0, "feedback": 0.0},
        "fixed": {"shape": 0.0, "feedback": 0.0},
        "outputs": ["out"],
    },
    "SawOscillator": {
        "inputs": ["frequency", "fm", "pm"],
        "connectable": {"frequency"},
        "params": {"frequency": 440.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "SquareOscillator": {
        "inputs": ["frequency", "fm", "pm"],
        "connectable": {"frequency"},
        "params": {"frequency": 440.0, "pulse_width": 0.5,
                   "pulse_width_sweep": 0.0},
        "fixed": {"pulse_width_sweep": 0.0},
        "outputs": ["out"],
    },
    "NoiseOscillator": {
        "inputs": ["frequency", "fm", "pm"],
        "connectable": {"frequency"},
        "params": {"frequency": 440.0, "steps": 32.0, "seed": 12345.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Noise": {
        "inputs": [], "connectable": set(),
        "params": {"colour": 0.0, "seed": 12345.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "LFO": {
        "inputs": ["rate"], "connectable": {"rate"},
        "params": {"rate": 2.0, "shape": 0.0, "amount": 1.0, "offset": 0.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "StateVariableFilter": {
        "inputs": ["in", "cutoff", "cutoff_mod", "resonance"],
        "connectable": {"in", "cutoff", "cutoff_mod", "resonance"},
        "params": {"cutoff": 1000.0, "resonance": 0.2, "mode": 0.0,
                   "cutoff_sweep": 0.0},
        "fixed": {"cutoff_sweep": 0.0},
        "outputs": ["out"],
    },
    "OnePoleFilter": {
        "inputs": ["in", "cutoff"], "connectable": {"in", "cutoff"},
        "params": {"cutoff": 1000.0, "mode": 0.0, "cutoff_sweep": 0.0},
        "fixed": {"cutoff_sweep": 0.0},
        "outputs": ["out"],
    },
    "Delay": {
        "inputs": ["in", "time", "feedback"],
        "connectable": {"in", "time", "feedback"},
        "params": {"time": 0.25, "feedback": 0.35, "mix": 0.35},
        "fixed": {},
        "outputs": ["out"],
    },
    "Comb": {
        "inputs": ["in", "frequency", "feedback", "damp"],
        "connectable": {"in", "frequency", "feedback", "damp"},
        "params": {"time": 0.03, "feedback": 0.84, "damp": 0.2},
        "fixed": {},
        "outputs": ["out"],
    },
    "Allpass": {
        "inputs": ["in"], "connectable": {"in"},
        "params": {"time": 0.005, "gain": 0.5},
        "fixed": {},
        "outputs": ["out"],
    },
    "Phaser": {
        "inputs": ["in", "offset"], "connectable": {"in", "offset"},
        "params": {"offset": 0.0, "sweep": 0.0, "depth": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Drive": {
        "inputs": ["in", "drive"], "connectable": {"in", "drive"},
        "params": {"drive": 4.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Crush": {
        "inputs": ["in"], "connectable": {"in"},
        "params": {"bits": 16.0, "rate": 48000.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Slide": {
        "inputs": ["frequency", "gate"], "connectable": {"frequency", "gate"},
        "params": {"slide": 0.0, "acceleration": 0.0, "limit": 0.0,
                   "frequency": 440.0},
        "fixed": {},
        "outputs": ["frequency"],
    },
    "Arpeggio": {
        "inputs": ["frequency", "gate"], "connectable": {"frequency", "gate"},
        "params": {"time": 0.05, "interval": 7.0, "frequency": 440.0},
        "fixed": {},
        "outputs": ["frequency"],
    },
    "ADSR": {
        "inputs": ["gate"], "connectable": {"gate"},
        "params": {"attack": 0.005, "decay": 0.120, "sustain": 0.6,
                   "release": 0.250},
        "fixed": {},
        "outputs": ["out"],
    },
    "AhdEnvelope": {
        "inputs": ["gate"], "connectable": {"gate"},
        "params": {"attack": 0.0, "hold": 0.1, "decay": 0.3, "punch": 0.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Retrigger": {
        "inputs": ["rate"], "connectable": {"rate"},
        "params": {"rate": 8.0, "width": 1.0},
        "fixed": {},
        "outputs": ["gate"],
    },
    "Gain": {
        "inputs": ["in", "gain"], "connectable": {"in", "gain"},
        "params": {"gain": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Level": {
        "inputs": ["in"], "connectable": {"in"},
        "params": {"level": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "StereoLevel": {
        "inputs": ["left", "right"], "connectable": {"left", "right"},
        "params": {"level": 1.0},
        "fixed": {},
        "outputs": ["left", "right"],
    },
    "Speech": {
        "inputs": ["trigger", "note"], "connectable": {"trigger", "note"},
        "params": {"pitch": 1.0, "speed": 1.0, "level": 1.0, "loop": 0.0,
                   "root": 130.81},
        "fixed": {},
        "outputs": ["out"],
    },
    "Sampler": {
        "inputs": ["gate", "frequency", "slice"],
        "connectable": {"gate", "frequency", "slice"},
        "params": {"level": 0.8, "loop": 0.0, "root": 261.63, "slices": 1.0,
                   "start": 0.0, "length": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Constant": {
        "inputs": [], "connectable": set(),
        "params": {"value": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Add": {
        "inputs": ["a", "b"], "connectable": {"a", "b"},
        "params": {"offset": 0.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Multiply": {
        "inputs": ["a", "b"], "connectable": {"a", "b"},
        "params": {"factor": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Mixer": {
        "inputs": ["in1", "in2", "in3", "in4"],
        "connectable": {"in1", "in2", "in3", "in4"},
        "params": {"level1": 1.0, "level2": 1.0, "level3": 1.0, "level4": 1.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "StereoOutput": {
        "inputs": ["left", "right"], "connectable": {"left", "right"},
        "params": {"level": 1.0, "safety_limit": 1.0},
        "fixed": {},
        "outputs": [],
    },
}


def _resolve(patch_path):
    """Run the patch through patch-io: load (any schema version), expand,
    validate, and hand back the flattened graph with the engine's schedule."""
    if not SG_VALIDATE.exists():
        raise Unsupported(
            f"{SG_VALIDATE} is not built — run: cmake --build build "
            "--target sg-validate")
    BUILD.mkdir(exist_ok=True)
    out = BUILD / "resolved.json"
    result = subprocess.run(
        [str(SG_VALIDATE), str(patch_path), "--resolve", str(out), "--quiet"],
        capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        raise Unsupported(
            f"patch-io rejected {patch_path.name}"
            + (f": {detail[:400]}" if detail else " (sg-validate exit 1)"))
    return json.loads(out.read_text())


def _validate(resolved):
    nodes = {}
    for n in resolved["nodes"]:
        t = n["type"]
        if "\x1f" in n["id"]:
            raise Unsupported("polyphonic patches (voices > 1) are not "
                              "supported on the Axoloti target yet")
        if t not in SUPPORTED:
            raise Unsupported(f"node type {t!r} is not in the Axoloti subset")
        spec = SUPPORTED[t]
        params = dict(spec["params"])
        for k, v in n.get("parameters", {}).items():
            if k not in params:
                raise Unsupported(f"{n['id']}: unknown parameter {k!r}")
            params[k] = float(v)
        for name, required in spec["fixed"].items():
            if params[name] != required:
                raise Unsupported(
                    f"{n['id']}: parameter {name!r}={params[name]} — this "
                    f"target only supports {name}={required}")
        nodes[n["id"]] = {"type": t, "params": params,
                          "buffer": n.get("buffer", "")}

    # Every wire, in document order; summing legality was already ruled on by
    # the native validator, so multiple sources per input are simply collected.
    feedback_set = set(resolved["schedule"]["feedback_connections"])
    bindings = {}  # (node, port) -> {"sources": [(src, port)...], "fb": bool}
    for index, c in enumerate(resolved["connections"]):
        dst, port = c["to"], c["to_port"]
        dspec = SUPPORTED[nodes[dst]["type"]]
        if port not in dspec["inputs"]:
            raise Unsupported(f"unknown input port {dst}.{port!r}")
        if port not in dspec["connectable"]:
            raise Unsupported(
                f"{dst}.{port}: connecting this input is not supported on "
                "the Axoloti target yet")
        sspec = SUPPORTED[nodes[c["from"]]["type"]]
        if c["from_port"] not in sspec["outputs"]:
            raise Unsupported(
                f"unknown output port {c['from']}.{c['from_port']!r}")
        binding = bindings.setdefault((dst, port), {"sources": [], "fb": False})
        binding["sources"].append((c["from"], c["from_port"]))
        if index in feedback_set:
            binding["fb"] = True

    outs = [i for i, n in nodes.items() if n["type"] == "StereoOutput"]
    if len(outs) != 1:
        raise Unsupported(f"need exactly one StereoOutput, found {len(outs)}")

    order = resolved["schedule"]["execution_order"]
    if sorted(order) != sorted(nodes):
        raise Unsupported("schedule does not cover the node set — resolver "
                          "and patch disagree")
    return nodes, bindings, order


def _cid(node_id):
    return "".join(ch if ch.isalnum() else "_" for ch in node_id)


def _plan_buffers(resolved, nodes):
    """Assign each referenced buffer an SDRAM address; returns
    (placements: id -> (addr, frames, rate_step_lit), uploads: [(addr, path)])."""
    described = {b["id"]: b for b in resolved.get("buffers", [])}
    referenced = {n["buffer"] for n in nodes.values() if n["buffer"]}
    placements, uploads = {}, []
    cursor = BUFFER_POOL_BASE
    for bid in sorted(referenced):
        if bid not in described:
            raise Unsupported(f"buffer {bid!r} is named but not carried")
        b = described[bid]
        nbytes = b["frames"] * 4
        if cursor + nbytes > BUFFER_POOL_BASE + BUFFER_POOL_SIZE:
            raise Unsupported(
                f"sample buffers exceed the {BUFFER_POOL_SIZE // 1048576} MB "
                "SDRAM pool")
        # PrepareContext: rate_step = float(buffer_sample_rate / sample_rate).
        rate_step = f32(float(b["sample_rate"]) / SAMPLE_RATE)
        placements[bid] = (cursor, b["frames"], rate_step)
        uploads.append((cursor, pathlib.Path(b["file"])))
        cursor += (nbytes + 3) & ~3
    return placements, uploads


def _emit(nodes, bindings, order, frames, patch_id, events, zero_input,
          buffer_placements):
    L = ["// Generated by sgaxo/codegen.py — do not edit.",
         '#include "kernels.h"', ""]
    init = []
    note_nodes = []
    sdram_bytes = 0

    used_outputs = {s for b in bindings.values() for s in b["sources"]}
    # AudioInput's kernel always writes both channels.
    for i, n in nodes.items():
        if n["type"] == "AudioInput":
            used_outputs.add((i, "left"))
            used_outputs.add((i, "right"))

    def buf(i, port):
        return f"buf_{_cid(i)}_{port}"

    def fbbuf(i, port):
        return f"fb_{_cid(i)}_{port}"

    def mixbuf(i, port):
        return f"mix_{_cid(i)}_{port}"

    # --- state and buffers ---------------------------------------------------
    for i in order:
        n = nodes[i]
        t, c = n["type"], _cid(i)
        for port in SUPPORTED[t]["outputs"]:
            if (i, port) in used_outputs:
                L.append(f"static float {buf(i, port)}[SGAXO_FRAMES];")
        if t == "NoteInput":
            L.append(f"static sgaxo::NoteState st_{c};")
            init += [f"st_{c}.target_note = 60.0f;",
                     f"st_{c}.current_note = 60.0f;"]
            note_nodes.append(i)
        elif t in ("SineOscillator", "SawOscillator", "SquareOscillator"):
            L.append(f"static sgaxo::OscState st_{c};")
        elif t == "NoiseOscillator":
            L.append(f"static sgaxo::NoiseOscState st_{c};")
            seed = int(f32(n["params"]["seed"])) & 0xFFFFFFFF
            init.append(f"st_{c}.rng.seed({seed}u);")
            init.append(f"st_{c}.last_phase = 1.0f;")
        elif t == "Noise":
            L.append(f"static sgaxo::NoiseState st_{c};")
            seed = int(f32(n["params"]["seed"])) & 0xFFFFFFFF
            init.append(f"st_{c}.rng.seed({seed}u);")
        elif t == "LFO":
            L.append(f"static sgaxo::LfoState st_{c};")
            init.append(f"st_{c}.rng.seed(0x5EED1234u);")
        elif t == "StateVariableFilter":
            L.append(f"static sgaxo::SvfState st_{c};")
        elif t == "OnePoleFilter":
            L.append(f"static sgaxo::OnePoleState st_{c};")
        elif t == "Delay":
            sdram_bytes += 96004 * 4
            L.append(f"static sgaxo::DelayState st_{c};")
            L.append(f"__attribute__((section(\".sdram\"))) "
                     f"static float line_{c}[SGAXO_DELAY_CAPACITY];")
            init.append(f"for (int j = 0; j < SGAXO_DELAY_CAPACITY; j++) "
                        f"line_{c}[j] = 0.0f;")
        elif t == "Comb":
            sdram_bytes += 4804 * 4
            L.append(f"static sgaxo::CombState st_{c};")
            L.append(f"__attribute__((section(\".sdram\"))) "
                     f"static float line_{c}[SGAXO_COMB_CAPACITY];")
            init.append(f"for (int j = 0; j < SGAXO_COMB_CAPACITY; j++) "
                        f"line_{c}[j] = 0.0f;")
        elif t == "Allpass":
            sdram_bytes += 2404 * 4
            L.append(f"static sgaxo::AllpassState st_{c};")
            L.append(f"__attribute__((section(\".sdram\"))) "
                     f"static float line_{c}[SGAXO_ALLPASS_CAPACITY];")
            init.append(f"for (int j = 0; j < SGAXO_ALLPASS_CAPACITY; j++) "
                        f"line_{c}[j] = 0.0f;")
        elif t == "Phaser":
            L.append(f"static sgaxo::PhaserState st_{c};")
        elif t == "Slide":
            L.append(f"static sgaxo::SlideState st_{c};")
        elif t == "Arpeggio":
            L.append(f"static sgaxo::ArpeggioState st_{c};")
        elif t == "Crush":
            L.append(f"static sgaxo::CrushState st_{c};")
            init.append(f"st_{c}.phase = 1.0f;")
        elif t == "ADSR":
            L.append(f"static sgaxo::AdsrState st_{c};")
        elif t == "AhdEnvelope":
            L.append(f"static sgaxo::AhdState st_{c};")
        elif t == "Retrigger":
            L.append(f"static sgaxo::RetriggerState st_{c};")
        elif t == "Sampler":
            L.append(f"static sgaxo::SamplerState st_{c};")
        elif t == "Speech":
            L.append(f"static sgaxo::SpeechState st_{c};")
            if n["buffer"] and n["buffer"] in buffer_placements:
                addr, bframes, _rs = buffer_placements[n["buffer"]]
                init.append(f"sgaxo::speech_init(st_{c}, "
                            f"(const float *){addr:#010x}u, {bframes});")
            else:
                init.append(f"sgaxo::speech_init(st_{c}, 0, 0);")

    if sdram_bytes > 0x400000:
        raise Unsupported(
            f"delay/comb/allpass lines need {sdram_bytes} bytes of SDRAM — "
            "more than the 4 MB below the capture buffer at 0xC0400000")

    # Feedback snapshot buffers, exactly graph.cpp's mix_buffer for feedback
    # bindings: the node reads last block's sum; the sum refreshes at block end.
    fb_bindings = [(dst, port, b) for (dst, port), b in bindings.items()
                   if b["fb"]]
    for dst, port, _b in fb_bindings:
        L.append(f"static float {fbbuf(dst, port)}[SGAXO_FRAMES];")
    # Premix buffers for multi-source inputs that are not feedback.
    for (dst, port), b in bindings.items():
        if not b["fb"] and len(b["sources"]) > 1:
            L.append(f"static float {mixbuf(dst, port)}[SGAXO_FRAMES];")
    if zero_input:
        L.append("static const float sg_zero[SGAXO_FRAMES] = {};")

    def src(i, port):
        b = bindings.get((i, port))
        if b is None:
            return "0"
        if b["fb"]:
            return fbbuf(i, port)
        if len(b["sources"]) > 1:
            return mixbuf(i, port)
        return buf(*b["sources"][0])

    # --- the graph, in the engine's own order --------------------------------
    L.append("")
    L.append("static void sg_graph_process(const float *sg_in_l, "
             "const float *sg_in_r, float *out_l, float *out_r) {")
    if zero_input:
        L.append("  (void)sg_in_l; (void)sg_in_r;")

    def emit_premixes(i):
        for port in SUPPORTED[nodes[i]["type"]]["inputs"]:
            b = bindings.get((i, port))
            if b is None or b["fb"] or len(b["sources"]) <= 1:
                continue
            m = mixbuf(i, port)
            first = buf(*b["sources"][0])
            L.append(f"  for (int j = 0; j < SGAXO_FRAMES; j++) "
                     f"{m}[j] = {first}[j];")
            for s in b["sources"][1:]:
                L.append(f"  for (int j = 0; j < SGAXO_FRAMES; j++) "
                         f"{m}[j] += {buf(*s)}[j];")

    for i in order:
        n, c = nodes[i], _cid(i)
        t, p = n["type"], n["params"]
        emit_premixes(i)
        if t == "NoteInput":
            glide = p["glide"]
            coeff = _exp_coeff(glide) if glide > 0.0 else 0.0
            outs = [buf(i, port) if (i, port) in used_outputs else "0"
                    for port in ("frequency", "gate", "velocity", "trigger")]
            L.append(f"  sgaxo::k_note_input(st_{c}, {', '.join(outs)}, "
                     f"{_lit(coeff)}, {_lit(p['transpose'])});")
        elif t == "AudioInput":
            in_l = "sg_zero" if zero_input else "sg_in_l"
            in_r = "sg_zero" if zero_input else "sg_in_r"
            L.append(f"  sgaxo::k_audio_input({in_l}, {in_r}, "
                     f"{buf(i, 'left')}, {buf(i, 'right')}, {_lit(p['gain'])});")
        elif t == "SineOscillator":
            L.append(f"  sgaxo::k_sine(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, {_lit(SAMPLE_RATE)});")
        elif t == "SawOscillator":
            L.append(f"  sgaxo::k_saw(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, {_lit(SAMPLE_RATE)});")
        elif t == "SquareOscillator":
            L.append(f"  sgaxo::k_square(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, "
                     f"{_lit(p['pulse_width'])}, {_lit(SAMPLE_RATE)});")
        elif t == "NoiseOscillator":
            L.append(f"  sgaxo::k_noise_osc(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, "
                     f"{_lit(p['steps'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Noise":
            pink = 1 if p["colour"] >= 0.5 else 0
            L.append(f"  sgaxo::k_noise(st_{c}, {buf(i, 'out')}, {pink});")
        elif t == "LFO":
            L.append(f"  sgaxo::k_lfo(st_{c}, {src(i, 'rate')}, {buf(i, 'out')}, "
                     f"{_lit(p['rate'])}, {int(p['shape'])}, {_lit(p['amount'])}, "
                     f"{_lit(p['offset'])}, {_lit(SAMPLE_RATE)});")
        elif t == "StateVariableFilter":
            L.append(f"  sgaxo::k_svf(st_{c}, {src(i, 'in')}, {src(i, 'cutoff')}, "
                     f"{src(i, 'cutoff_mod')}, {src(i, 'resonance')}, "
                     f"{buf(i, 'out')}, {_lit(p['cutoff'])}, "
                     f"{_lit(p['resonance'])}, {int(p['mode'])}, {_lit(SAMPLE_RATE)});")
        elif t == "OnePoleFilter":
            L.append(f"  sgaxo::k_onepole(st_{c}, {src(i, 'in')}, "
                     f"{src(i, 'cutoff')}, {buf(i, 'out')}, {_lit(p['cutoff'])}, "
                     f"{int(p['mode'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Delay":
            L.append(f"  sgaxo::k_delay(st_{c}, line_{c}, {src(i, 'in')}, "
                     f"{src(i, 'time')}, {src(i, 'feedback')}, {buf(i, 'out')}, "
                     f"{_lit(p['time'])}, {_lit(p['feedback'])}, "
                     f"{_lit(p['mix'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Comb":
            L.append(f"  sgaxo::k_comb(st_{c}, line_{c}, {src(i, 'in')}, "
                     f"{src(i, 'frequency')}, {src(i, 'feedback')}, "
                     f"{src(i, 'damp')}, {buf(i, 'out')}, {_lit(p['time'])}, "
                     f"{_lit(p['feedback'])}, {_lit(p['damp'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Allpass":
            L.append(f"  sgaxo::k_allpass(st_{c}, line_{c}, {src(i, 'in')}, "
                     f"{buf(i, 'out')}, {_lit(p['time'])}, {_lit(p['gain'])}, "
                     f"{_lit(SAMPLE_RATE)});")
        elif t == "Phaser":
            L.append(f"  sgaxo::k_phaser(st_{c}, {src(i, 'in')}, "
                     f"{src(i, 'offset')}, {buf(i, 'out')}, {_lit(p['offset'])}, "
                     f"{_lit(p['sweep'])}, {_lit(p['depth'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Drive":
            L.append(f"  sgaxo::k_drive({src(i, 'in')}, {src(i, 'drive')}, "
                     f"{buf(i, 'out')}, {_lit(p['drive'])});")
        elif t == "Crush":
            inc = f32(min(max(f32(p["rate"]), 500.0), SAMPLE_RATE) / SAMPLE_RATE)
            levels = f32(2.0 ** f32(f32(p["bits"]) - 1.0))
            L.append(f"  sgaxo::k_crush(st_{c}, {src(i, 'in')}, {buf(i, 'out')}, "
                     f"{_lit(inc)}, {_lit(levels)});")
        elif t == "Slide":
            L.append(f"  sgaxo::k_slide(st_{c}, {src(i, 'frequency')}, "
                     f"{src(i, 'gate')}, {buf(i, 'frequency')}, {_lit(p['slide'])}, "
                     f"{_lit(p['acceleration'])}, {_lit(p['limit'])}, "
                     f"{_lit(p['frequency'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Arpeggio":
            ratio = f32(2.0 ** f32(f32(p["interval"]) / 12.0))
            dt = f32(1.0 / SAMPLE_RATE)
            L.append(f"  sgaxo::k_arpeggio(st_{c}, {src(i, 'frequency')}, "
                     f"{src(i, 'gate')}, {buf(i, 'frequency')}, {_lit(p['time'])}, "
                     f"{_lit(ratio)}, {_lit(p['frequency'])}, {_lit(dt)});")
        elif t == "ADSR":
            L.append(f"  sgaxo::k_adsr(st_{c}, {src(i, 'gate')}, {buf(i, 'out')}, "
                     f"{_lit(_attack_step(p['attack']))}, "
                     f"{_lit(_exp_coeff(p['decay']))}, {_lit(p['sustain'])}, "
                     f"{_lit(_exp_coeff(p['release']))});")
        elif t == "AhdEnvelope":
            dt = f32(1.0 / SAMPLE_RATE)
            L.append(f"  sgaxo::k_ahd(st_{c}, {src(i, 'gate')}, {buf(i, 'out')}, "
                     f"{_lit(p['attack'])}, {_lit(p['hold'])}, "
                     f"{_lit(p['decay'])}, {_lit(p['punch'])}, {_lit(dt)});")
        elif t == "Retrigger":
            width_s = f32(f32(p["width"]) * f32(0.001))
            dt = f32(1.0 / SAMPLE_RATE)
            L.append(f"  sgaxo::k_retrigger(st_{c}, {src(i, 'rate')}, "
                     f"{buf(i, 'gate')}, {_lit(p['rate'])}, {_lit(width_s)}, "
                     f"{_lit(dt)});")
        elif t == "Gain":
            L.append(f"  sgaxo::k_gain({src(i, 'in')}, {src(i, 'gain')}, "
                     f"{buf(i, 'out')}, {_lit(p['gain'])});")
        elif t == "Level":
            L.append(f"  sgaxo::k_level({src(i, 'in')}, {buf(i, 'out')}, "
                     f"{_lit(p['level'])});")
        elif t == "StereoLevel":
            L.append(f"  sgaxo::k_stereo_level({src(i, 'left')}, "
                     f"{src(i, 'right')}, {buf(i, 'left')}, {buf(i, 'right')}, "
                     f"{_lit(p['level'])});")
        elif t == "Speech":
            speed = f32(p["speed"])
            step = f32(8000.0 / SAMPLE_RATE)
            loop = 1 if p["loop"] > 0.5 else 0
            L.append(f"  sgaxo::k_speech(st_{c}, {src(i, 'trigger')}, "
                     f"{src(i, 'note')}, {buf(i, 'out')}, {_lit(p['pitch'])}, "
                     f"{_lit(speed)}, {_lit(p['level'])}, {loop}, "
                     f"{_lit(p['root'])}, {_lit(step)});")
        elif t == "Sampler":
            if n["buffer"] and n["buffer"] in buffer_placements:
                addr, bframes, rate_step = buffer_placements[n["buffer"]]
                data = f"(const float *){addr:#010x}u"
            else:
                data, bframes, rate_step = "0", 0, 1.0
            slices = int(min(max(f32(p["slices"]) + 0.5, 1.0), 16.0))
            loop = 1 if p["loop"] >= 0.5 else 0
            L.append(f"  sgaxo::k_sampler(st_{c}, {src(i, 'gate')}, "
                     f"{src(i, 'frequency')}, {src(i, 'slice')}, {buf(i, 'out')}, "
                     f"{_lit(p['level'])}, {loop}, {_lit(p['root'])}, {slices}, "
                     f"{_lit(p['start'])}, {_lit(p['length'])}, {data}, "
                     f"{bframes}, {_lit(rate_step)});")
        elif t == "Constant":
            L.append(f"  sgaxo::k_constant({buf(i, 'out')}, {_lit(p['value'])});")
        elif t == "Add":
            L.append(f"  sgaxo::k_add({src(i, 'a')}, {src(i, 'b')}, "
                     f"{buf(i, 'out')}, {_lit(p['offset'])});")
        elif t == "Multiply":
            L.append(f"  sgaxo::k_multiply({src(i, 'a')}, {src(i, 'b')}, "
                     f"{buf(i, 'out')}, {_lit(p['factor'])});")
        elif t == "Mixer":
            ins = ", ".join(src(i, f"in{k}") for k in (1, 2, 3, 4))
            lvls = ", ".join(_lit(p[f"level{k}"]) for k in (1, 2, 3, 4))
            L.append(f"  sgaxo::k_mixer({ins}, {buf(i, 'out')}, {lvls});")
        elif t == "StereoOutput":
            limit = 1 if p["safety_limit"] >= 0.5 else 0
            L.append(f"  sgaxo::k_stereo_output({src(i, 'left')}, "
                     f"{src(i, 'right')}, out_l, out_r, {_lit(p['level'])}, "
                     f"{limit});")

    # Block-end feedback snapshot, exactly Graph::snapshot_feedback: zero the
    # buffer, then accumulate every source of the feedback-marked input.
    for dst, port, b in fb_bindings:
        m = fbbuf(dst, port)
        L.append(f"  for (int j = 0; j < SGAXO_FRAMES; j++) {m}[j] = 0.0f;")
        for s in b["sources"]:
            L.append(f"  for (int j = 0; j < SGAXO_FRAMES; j++) "
                     f"{m}[j] += {buf(*s)}[j];")
    L.append("}")
    L.append("")

    L.append("static void sg_graph_init(void) {")
    for line in init:
        L.append(f"  {line}")
    L.append("}")
    L.append("")

    L.append("static void sg_note_event(int on, int note, float velocity) {")
    if note_nodes:
        for i in note_nodes:
            L.append(f"  sgaxo::note_event(st_{_cid(i)}, on, note, velocity, "
                     f"{_lit(SAMPLE_RATE)});")
    else:
        L.append("  (void)on; (void)note; (void)velocity;")
    L.append("}")
    L.append("")

    L.append("static const sgaxo_event_t sg_events[] = {")
    for frame, on, note, vel in events:
        L.append(f"  {{{frame}, {1 if on else 0}, {note}, {_lit(vel)}}},")
    L.append("  {0, 0, 0, 0.0f},  // terminator slot; count below is what rules")
    L.append("};")
    L.append(f"static const int sg_event_count = {len(events)};")
    L.append("")
    L.append(f"#define SGAXO_PATCH_ID {patch_id:#010x}")
    L.append(f"#define SGAXO_FRAMES_TARGET {frames}")
    L.append('#include "runtime_tail.h"')
    L.append("")
    return "\n".join(L)


def patch_id_for(name):
    return 0x80000000 | (zlib.crc32(name.encode()) & 0x7FFFFFFF)


def build_patch(patch_path, frames=4800, name=None, events=(),
                zero_input=True):
    """Compile `patch_path` for the Axoloti; returns (binary_bytes, patch_id).

    events: (frame, note_on, note, velocity) tuples, delivered on 64-frame
    block boundaries exactly like the golden runner.
    zero_input: feed silence to AudioInput (deterministic tests). False wires
    the codec's real input — the effects-box configuration.

    Returns (binary, patch_id, buffer_uploads) where buffer_uploads is a list
    of (sdram_address, bytes) the host must write before starting the patch.
    """
    name = name or pathlib.Path(patch_path).stem
    resolved = _resolve(pathlib.Path(patch_path))
    nodes, bindings, order = _validate(resolved)
    placements, uploads = _plan_buffers(resolved, nodes)
    pid = patch_id_for(name)
    source = _emit(nodes, bindings, order, frames, pid, list(events),
                   zero_input, placements)

    BUILD.mkdir(exist_ok=True)
    cpp = BUILD / f"{name}.cpp"
    cpp.write_text(source)
    obj, elf, binp = (BUILD / f"{name}.{ext}" for ext in ("o", "elf", "bin"))
    inc = ["-I", str(HERE), "-I", str(RIG / "patches"), "-I", str(DSP_CORE_SRC)]
    subprocess.run([CXX, *CXXFLAGS, *inc, "-c", str(cpp), "-o", str(obj)],
                   check=True)
    libgcc = subprocess.run(
        [CXX.replace("g++", "gcc"), "-mcpu=cortex-m4", "-mfloat-abi=hard",
         "-mfpu=fpv4-sp-d16", "-mthumb", "-print-libgcc-file-name"],
        capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run(
        [CXX, "-nostdlib", "-nostartfiles", f"-T{SDK}/ramlink.ld",
         "-mcpu=cortex-m4", "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16", "-mthumb",
         f"-Wl,--just-symbols={SDK}/axoloti.elf", str(obj), libgcc,
         "-o", str(elf)],
        check=True)
    # The patch .data section is NOLOAD: initialized statics would arrive as
    # garbage. Refuse to ship a binary that has one.
    nm = subprocess.run([NM, "-S", str(elf)], capture_output=True, text=True,
                        check=True).stdout
    for line in nm.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[2] in ("d", "D") and int(parts[1], 16) > 0:
            raise Unsupported(f"initialized .data would be lost on load: {line}")
    subprocess.run([OBJCOPY, "-O", "binary", str(elf), str(binp)], check=True)
    buffer_uploads = [(addr, path.read_bytes()) for addr, path in uploads]
    return binp.read_bytes(), pid, buffer_uploads


if __name__ == "__main__":
    import sys
    binary, pid, buffers = build_patch(pathlib.Path(sys.argv[1]))
    print(f"{len(binary)} bytes, patch id {pid:#010x}, "
          f"{len(buffers)} buffer(s), "
          f"{sum(len(b) for _a, b in buffers)} buffer bytes")
