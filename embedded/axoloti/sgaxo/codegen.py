"""sgaxo: compile a soundgraph patch (JSON) into an Axoloti patch binary.

The soundgraph workflow the Axoloti audience already knows: a program on the
computer turns the patch into code, compiles it, and programs the board. This
is that program. It supports a declared subset of the node vocabulary
(SUPPORTED below); anything outside the subset is refused with a message that
names the node and the reason — never silently degraded.

Fidelity rules:
- The generated graph runs at dsp-core's 64-frame block size (kernels.h).
- Every coefficient derived only from parameters (ADSR exp() curves, glide)
  is computed HERE, in double precision with float32-emulated intermediate
  steps, and baked as a literal — bit-identical to what native computes.
- Top-level "Input"/"Output" seams map to NoteInput/StereoOutput exactly as
  patch-io's terminal_for() does for the note/stereo host.

Usage as a library (the tests do this):
    from codegen import build_patch
    binary, patch_id = build_patch(path, frames=24000, events=[(0, True, 45, 0.9)])
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
DSP_CORE_SRC = RIG.parent.parent / "dsp-core" / "src"

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


# The declared subset. inputs: port -> kernel argument slot order;
# connectable: which of those may have a wire; fixed: parameter values this
# target requires (refused otherwise); defaults from the node descriptors.
SUPPORTED = {
    "Input": {  # top-level note seam -> NoteInput (patch-io terminal_for)
        "inputs": [], "connectable": set(),
        "params": {"glide": 0.0, "transpose": 0.0, "voices": 1.0},
        "fixed": {"voices": 1.0},
        "outputs": ["frequency", "gate", "velocity", "trigger"],
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
    "ADSR": {
        "inputs": ["gate"], "connectable": {"gate"},
        "params": {"attack": 0.005, "decay": 0.120, "sustain": 0.6,
                   "release": 0.250},
        "fixed": {},
        "outputs": ["out"],
    },
    "Gain": {
        "inputs": ["in", "gain"], "connectable": {"in", "gain"},
        "params": {"gain": 1.0},
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
    "SquareOscillator": {
        "inputs": ["frequency", "fm", "pm"],
        "connectable": {"frequency"},
        "params": {"frequency": 440.0, "pulse_width": 0.5,
                   "pulse_width_sweep": 0.0},
        "fixed": {"pulse_width_sweep": 0.0},
        "outputs": ["out"],
    },
    "Noise": {
        "inputs": [], "connectable": set(),
        "params": {"colour": 0.0, "seed": 12345.0},
        "fixed": {},
        "outputs": ["out"],
    },
    "Delay": {
        "inputs": ["in", "time", "feedback"],
        "connectable": {"in", "time", "feedback"},
        "params": {"time": 0.25, "feedback": 0.35, "mix": 0.35},
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
    "StereoOutput": {
        "inputs": ["left", "right"], "connectable": {"left", "right"},
        "params": {"level": 1.0, "safety_limit": 1.0},
        "fixed": {},
        "outputs": [],
    },
}
SUPPORTED["Output"] = SUPPORTED["StereoOutput"]  # top-level stereo seam


def _load(patch_path):
    doc = json.loads(patch_path.read_text())
    if doc.get("schema_version") != 1:
        raise Unsupported(f"schema_version {doc.get('schema_version')}")
    return doc


def _validate(doc):
    nodes = {}
    for n in doc["nodes"]:
        t = n["type"]
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
        nodes[n["id"]] = {"type": t, "params": params}

    wires = {}  # (dst node, dst port) -> (src node, src port)
    for c in doc.get("connections", []):
        src, dst = c["from"], c["to"]
        for end in (src["node"], dst["node"]):
            if end not in nodes:
                raise Unsupported(f"connection references unknown node {end!r}")
        sspec = SUPPORTED[nodes[src["node"]]["type"]]
        dspec = SUPPORTED[nodes[dst["node"]]["type"]]
        if src["port"] not in sspec["outputs"]:
            raise Unsupported(f"unknown output port "
                              f"{src['node']}.{src['port']!r}")
        if dst["port"] not in dspec["inputs"]:
            raise Unsupported(f"unknown input port {dst['node']}.{dst['port']!r}")
        if dst["port"] not in dspec["connectable"]:
            raise Unsupported(
                f"{dst['node']}.{dst['port']}: connecting this input is not "
                "supported on the Axoloti target yet")
        key = (dst["node"], dst["port"])
        if key in wires:
            raise Unsupported(
                f"{dst['node']}.{dst['port']}: summing inputs are not "
                "supported on the Axoloti target yet")
        wires[key] = (src["node"], src["port"])

    outs = [i for i, n in nodes.items()
            if n["type"] in ("StereoOutput", "Output")]
    if len(outs) != 1:
        raise Unsupported(f"need exactly one Output, found {len(outs)}")
    return nodes, wires


def _topo_order(nodes, wires):
    deps = {i: set() for i in nodes}
    for (dst, _p), (src, _sp) in wires.items():
        deps[dst].add(src)
    order, done = [], set()

    def visit(i, path):
        if i in done:
            return
        if i in path:
            raise Unsupported(f"cycle through {i!r} (no Delay in the subset yet)")
        for d in sorted(deps[i]):
            visit(d, path | {i})
        done.add(i)
        order.append(i)

    for i in sorted(nodes):
        visit(i, set())
    return order


def _cid(node_id):
    return "".join(ch if ch.isalnum() else "_" for ch in node_id)


def _emit(nodes, wires, order, frames, patch_id, events):
    L = ["// Generated by sgaxo/codegen.py — do not edit.",
         '#include "kernels.h"', ""]
    init = []
    note_nodes = []
    delay_count = 0

    used_outputs = {(s, sp) for (s, sp) in wires.values()}

    def buf(i, port):
        return f"buf_{_cid(i)}_{port}"

    def src(dst, port):
        w = wires.get((dst, port))
        return buf(*w) if w is not None else "0"

    for i in order:
        n = nodes[i]
        t, c = n["type"], _cid(i)
        for port in SUPPORTED[t]["outputs"]:
            if (i, port) in used_outputs:
                L.append(f"static float {buf(i, port)}[SGAXO_FRAMES];")
        if t == "Input":
            L.append(f"static sgaxo::NoteState st_{c};")
            init += [f"st_{c}.target_note = 60.0f;",
                     f"st_{c}.current_note = 60.0f;"]
            note_nodes.append(i)
        elif t in ("SineOscillator", "SawOscillator", "SquareOscillator"):
            L.append(f"static sgaxo::OscState st_{c};")
        elif t == "LFO":
            L.append(f"static sgaxo::LfoState st_{c};")
            init.append(f"st_{c}.rng.seed(0x5EED1234u);")
        elif t == "StateVariableFilter":
            L.append(f"static sgaxo::SvfState st_{c};")
        elif t == "ADSR":
            L.append(f"static sgaxo::AdsrState st_{c};")
        elif t == "Noise":
            L.append(f"static sgaxo::NoiseState st_{c};")
            # Through float32 like every parameter: native stores the seed in a
            # float, so 20260807 seeds as 20260808 — and so must we.
            seed = int(f32(n["params"]["seed"])) & 0xFFFFFFFF
            init.append(f"st_{c}.rng.seed({seed}u);")
        elif t == "Delay":
            delay_count += 1
            if delay_count > 10:
                raise Unsupported(
                    "more than 10 Delay nodes: their SDRAM lines would "
                    "collide with the capture buffer at 0xC0400000")
            L.append(f"static sgaxo::DelayState st_{c};")
            L.append(f"__attribute__((section(\".sdram\"))) "
                     f"static float line_{c}[SGAXO_DELAY_CAPACITY];")
            # .sdram is NOLOAD: this is DelayNode::reset(), done at init.
            init.append(f"for (int j = 0; j < SGAXO_DELAY_CAPACITY; j++) "
                        f"line_{c}[j] = 0.0f;")
        elif t == "AhdEnvelope":
            L.append(f"static sgaxo::AhdState st_{c};")
        elif t == "Retrigger":
            L.append(f"static sgaxo::RetriggerState st_{c};")

    L.append("")
    L.append("static void sg_graph_process(float *out_l, float *out_r) {")
    for i in order:
        n, c = nodes[i], _cid(i)
        t, p = n["type"], n["params"]
        if t == "Input":
            glide = p["glide"]
            coeff = _exp_coeff(glide) if glide > 0.0 else 0.0
            outs = [buf(i, port) if (i, port) in used_outputs else "0"
                    for port in ("frequency", "gate", "velocity", "trigger")]
            L.append(f"  sgaxo::k_note_input(st_{c}, {', '.join(outs)}, "
                     f"{_lit(coeff)}, {_lit(p['transpose'])});")
        elif t == "SineOscillator":
            L.append(f"  sgaxo::k_sine(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, {_lit(SAMPLE_RATE)});")
        elif t == "SawOscillator":
            L.append(f"  sgaxo::k_saw(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, {_lit(SAMPLE_RATE)});")
        elif t == "LFO":
            L.append(f"  sgaxo::k_lfo(st_{c}, {src(i, 'rate')}, {buf(i, 'out')}, "
                     f"{_lit(p['rate'])}, {int(p['shape'])}, {_lit(p['amount'])}, "
                     f"{_lit(p['offset'])}, {_lit(SAMPLE_RATE)});")
        elif t == "StateVariableFilter":
            L.append(f"  sgaxo::k_svf(st_{c}, {src(i, 'in')}, {src(i, 'cutoff')}, "
                     f"{src(i, 'cutoff_mod')}, {src(i, 'resonance')}, "
                     f"{buf(i, 'out')}, {_lit(p['cutoff'])}, "
                     f"{_lit(p['resonance'])}, {int(p['mode'])}, {_lit(SAMPLE_RATE)});")
        elif t == "ADSR":
            L.append(f"  sgaxo::k_adsr(st_{c}, {src(i, 'gate')}, {buf(i, 'out')}, "
                     f"{_lit(_attack_step(p['attack']))}, "
                     f"{_lit(_exp_coeff(p['decay']))}, {_lit(p['sustain'])}, "
                     f"{_lit(_exp_coeff(p['release']))});")
        elif t == "Gain":
            L.append(f"  sgaxo::k_gain({src(i, 'in')}, {src(i, 'gain')}, "
                     f"{buf(i, 'out')}, {_lit(p['gain'])});")
        elif t == "SquareOscillator":
            L.append(f"  sgaxo::k_square(st_{c}, {src(i, 'frequency')}, "
                     f"{buf(i, 'out')}, {_lit(p['frequency'])}, "
                     f"{_lit(p['pulse_width'])}, {_lit(SAMPLE_RATE)});")
        elif t == "Noise":
            pink = 1 if p["colour"] >= 0.5 else 0
            L.append(f"  sgaxo::k_noise(st_{c}, {buf(i, 'out')}, {pink});")
        elif t == "Delay":
            L.append(f"  sgaxo::k_delay(st_{c}, line_{c}, {src(i, 'in')}, "
                     f"{src(i, 'time')}, {src(i, 'feedback')}, {buf(i, 'out')}, "
                     f"{_lit(p['time'])}, {_lit(p['feedback'])}, "
                     f"{_lit(p['mix'])}, {_lit(SAMPLE_RATE)});")
        elif t == "AhdEnvelope":
            dt = f32(1.0 / SAMPLE_RATE)
            L.append(f"  sgaxo::k_ahd(st_{c}, {src(i, 'gate')}, {buf(i, 'out')}, "
                     f"{_lit(p['attack'])}, {_lit(p['hold'])}, "
                     f"{_lit(p['decay'])}, {_lit(p['punch'])}, {_lit(dt)});")
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
        elif t == "Retrigger":
            width_s = f32(f32(p["width"]) * f32(0.001))
            dt = f32(1.0 / SAMPLE_RATE)
            L.append(f"  sgaxo::k_retrigger(st_{c}, {src(i, 'rate')}, "
                     f"{buf(i, 'gate')}, {_lit(p['rate'])}, {_lit(width_s)}, "
                     f"{_lit(dt)});")
        elif t in ("StereoOutput", "Output"):
            limit = 1 if p["safety_limit"] >= 0.5 else 0
            L.append(f"  sgaxo::k_stereo_output({src(i, 'left')}, "
                     f"{src(i, 'right')}, out_l, out_r, {_lit(p['level'])}, "
                     f"{limit});")
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


def build_patch(patch_path, frames=4800, name=None, events=()):
    """Compile `patch_path` for the Axoloti; returns (binary_bytes, patch_id).

    events: iterable of (frame, note_on: bool, note: int, velocity: float),
    replayed on 64-frame block boundaries exactly like the golden runner.
    """
    name = name or patch_path.stem
    doc = _load(patch_path)
    nodes, wires = _validate(doc)
    order = _topo_order(nodes, wires)
    pid = patch_id_for(name)
    source = _emit(nodes, wires, order, frames, pid, list(events))

    BUILD.mkdir(exist_ok=True)
    cpp = BUILD / f"{name}.cpp"
    cpp.write_text(source)
    obj, elf, binp = (BUILD / f"{name}.{ext}" for ext in ("o", "elf", "bin"))
    inc = ["-I", str(HERE), "-I", str(RIG / "patches"), "-I", str(DSP_CORE_SRC)]
    subprocess.run([CXX, *CXXFLAGS, *inc, "-c", str(cpp), "-o", str(obj)],
                   check=True)
    subprocess.run(
        [CXX, "-nostdlib", "-nostartfiles", f"-T{SDK}/ramlink.ld",
         "-mcpu=cortex-m4", "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16", "-mthumb",
         f"-Wl,--just-symbols={SDK}/axoloti.elf", str(obj), "-o", str(elf)],
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
    return binp.read_bytes(), pid


if __name__ == "__main__":
    import sys
    binary, pid = build_patch(pathlib.Path(sys.argv[1]))
    print(f"{len(binary)} bytes, patch id {pid:#010x}")
