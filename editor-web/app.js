// SoundGraph web host — the reference frontend.
//
// This is deliberately the plain one. It exists so there is a lightweight, zero-install
// way in, and so the Godot editor has something to be checked against: both open the same
// file and must mean the same thing by it.
//
// Nothing here knows any DSP. Controls are generated from the patch's own control
// surfaces, and every diagnostic shown comes from the same validator the command line
// tools use.
import { SoundGraph } from './soundgraph.js';

const engine = new SoundGraph();

// Exposed on purpose. The console is the fastest way to poke at a running graph, and the
// differential testing against the Godot editor will want a handle on this too.
window.soundgraph = engine;

const ui = {
    start: document.getElementById('start'),
    status: document.getElementById('status'),
    meterFill: document.getElementById('meter-fill'),
    patch: document.getElementById('patch'),
    apply: document.getElementById('apply'),
    save: document.getElementById('save'),
    open: document.getElementById('open'),
    examples: document.getElementById('examples'),
    diagnostics: document.getElementById('diagnostics'),
    controls: document.getElementById('controls'),
    keyboard: document.getElementById('keyboard'),
    info: document.getElementById('info'),
    midiStatus: document.getElementById('midi-status'),
};

const EXAMPLES = [
    { label: 'First Synth', path: '../examples/patches/first-synth.json' },
    { label: 'Delay Echo', path: '../examples/patches/delay-echo.json' },
];

let started = false;
let currentPatch = null;

// ---------------------------------------------------------------------------------
// Validation feedback
// ---------------------------------------------------------------------------------

function renderDiagnostics(diagnostics, { valid }) {
    ui.diagnostics.replaceChildren();

    if (diagnostics.length === 0) {
        const element = document.createElement('div');
        element.className = 'diagnostic ok';
        element.textContent = valid ? 'Valid patch.' : 'Patch could not be read.';
        ui.diagnostics.append(element);
        return;
    }

    for (const diagnostic of diagnostics) {
        const element = document.createElement('div');
        element.className = `diagnostic ${diagnostic.severity}`;

        const message = document.createElement('div');
        message.textContent = diagnostic.message;
        element.append(message);

        if (diagnostic.nodes?.length) {
            const where = document.createElement('div');
            where.className = 'where';
            where.textContent = diagnostic.nodes.join(' → ');
            element.append(where);
        }
        if (diagnostic.suggestion) {
            const suggestion = document.createElement('div');
            suggestion.className = 'suggestion';
            suggestion.textContent = diagnostic.suggestion;
            element.append(suggestion);
        }
        ui.diagnostics.append(element);
    }
}

function validateCurrentText() {
    if (!engine.tooling) {
        return null;
    }
    const result = engine.tooling.validate(ui.patch.value);
    renderDiagnostics(result.diagnostics, { valid: result.ok });
    return result;
}

// ---------------------------------------------------------------------------------
// Control surfaces
//
// The patch says which parameters are performable and how they should be scaled. The
// page just reflects that — it has no opinion about what a filter cutoff is.
// ---------------------------------------------------------------------------------

function toValue(control, t) {
    const min = control.min ?? 0;
    const max = control.max ?? 1;
    if (control.scaling === 'exponential' && min > 0 && max > 0) {
        return min * Math.pow(max / min, t);
    }
    if (control.scaling === 'logarithmic') {
        // Level-style controls: more travel near the quiet end, where hearing is fussier.
        return min + (max - min) * t * t;
    }
    return min + (max - min) * t;
}

function toPosition(control, value) {
    const min = control.min ?? 0;
    const max = control.max ?? 1;
    if (control.scaling === 'exponential' && min > 0 && max > 0) {
        return Math.log(value / min) / Math.log(max / min);
    }
    if (control.scaling === 'logarithmic') {
        return Math.sqrt(Math.max(0, (value - min) / (max - min)));
    }
    return (value - min) / (max - min);
}

function format(value) {
    const magnitude = Math.abs(value);
    if (magnitude >= 1000) return value.toFixed(0);
    if (magnitude >= 10) return value.toFixed(1);
    if (magnitude >= 1) return value.toFixed(2);
    return value.toFixed(3);
}

function buildControls(patch) {
    ui.controls.replaceChildren();
    const controls = patch.controls ?? [];

    if (controls.length === 0) {
        const hint = document.createElement('p');
        hint.className = 'hint';
        hint.textContent =
            'This patch declares no control surfaces. Add a "controls" entry to expose a parameter here.';
        ui.controls.append(hint);
        return;
    }

    for (const control of controls) {
        const node = control.target.node;
        const parameter = control.target.parameter;
        engine.bindParameter(node, parameter);

        const initial = control.default ?? findParameterValue(patch, node, parameter) ?? control.min ?? 0;

        const wrapper = document.createElement('div');
        wrapper.className = 'control';

        const label = document.createElement('label');
        const name = document.createElement('span');
        name.textContent = control.label || control.id;
        const readout = document.createElement('span');
        readout.className = 'value';
        readout.textContent = format(initial);
        label.append(name, readout);

        const slider = document.createElement('input');
        slider.type = 'range';
        slider.min = '0';
        slider.max = '1';
        slider.step = '0.001';
        slider.value = String(Math.min(1, Math.max(0, toPosition(control, initial))));

        const target = document.createElement('div');
        target.className = 'target';
        target.textContent = `${node}.${parameter}`;

        slider.addEventListener('input', () => {
            const value = toValue(control, Number(slider.value));
            readout.textContent = format(value);
            engine.setParameter(node, parameter, value);
        });
        // Release focus when the drag ends, so arrow keys go back to being arrow keys
        // instead of nudging the last-touched knob.
        slider.addEventListener('pointerup', () => slider.blur());

        wrapper.append(label, slider, target);
        ui.controls.append(wrapper);
    }
}

function findParameterValue(patch, nodeId, parameterName) {
    const node = (patch.nodes ?? []).find((candidate) => candidate.id === nodeId);
    return node?.parameters?.[parameterName];
}

// ---------------------------------------------------------------------------------
// What the graph is doing
// ---------------------------------------------------------------------------------

function renderInfo(info) {
    ui.info.replaceChildren();
    if (!info || !info.nodes) {
        return;
    }

    const order = document.createElement('div');
    const orderHeading = document.createElement('h3');
    orderHeading.textContent = 'Execution order';
    order.append(orderHeading);
    const list = document.createElement('div');
    list.className = 'order';
    list.textContent = info.nodes.map((node) => node.id).join('  →  ');
    order.append(list);
    ui.info.append(order);

    if (info.feedback?.length) {
        const heading = document.createElement('h3');
        heading.textContent = 'Feedback edges';
        const body = document.createElement('div');
        body.className = 'feedback';
        body.textContent = info.feedback
            .map((edge) => `${edge.from} → ${edge.to} (previous block)`)
            .join('\n');
        body.style.whiteSpace = 'pre-line';
        ui.info.append(heading, body);
    }

    const costHeading = document.createElement('h3');
    costHeading.textContent = 'Estimated cost';
    const cost = document.createElement('div');
    cost.textContent =
        `cpu ${info.cost.cpu.toFixed(1)} units · state ${info.cost.state_bytes} B · ` +
        `buffers ${(info.cost.heap_bytes / 1024).toFixed(1)} KB · ` +
        `${info.node_count} nodes at ${Math.round(info.sample_rate)} Hz`;
    ui.info.append(costHeading, cost);
}

// ---------------------------------------------------------------------------------
// Playing
// ---------------------------------------------------------------------------------

const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const BLACK_OFFSETS = { 1: true, 3: true, 6: true, 8: true, 10: true };
const KEY_MAP = {
    a: 0, w: 1, s: 2, e: 3, d: 4, f: 5, t: 6, g: 7, y: 8, h: 9, u: 10, j: 11,
    k: 12, o: 13, l: 14, p: 15, ';': 16,
};

let octave = 3;
const held = new Set();
const keyElements = new Map();

function noteOn(note) {
    if (held.has(note)) return;
    held.add(note);
    engine.noteOn(note, 0.9);
    keyElements.get(note)?.classList.add('held');
}

function noteOff(note) {
    if (!held.has(note)) return;
    held.delete(note);
    engine.noteOff(note);
    keyElements.get(note)?.classList.remove('held');
}

function buildKeyboard() {
    ui.keyboard.replaceChildren();
    keyElements.clear();

    const first = octave * 12 + 12;   // C of the current octave
    const count = 24;                 // two octaves
    const whiteNotes = [];
    for (let i = 0; i < count; i += 1) {
        if (!BLACK_OFFSETS[(first + i) % 12]) whiteNotes.push(first + i);
    }

    for (const note of whiteNotes) {
        const key = document.createElement('div');
        key.className = 'key';
        key.dataset.note = String(note);
        if (note % 12 === 0) {
            key.textContent = `${NOTE_NAMES[0]}${Math.floor(note / 12) - 1}`;
        }
        ui.keyboard.append(key);
        keyElements.set(note, key);
    }

    // Black keys are positioned over the gaps rather than laid out in flow.
    const whiteWidth = 100 / whiteNotes.length;
    let whiteIndex = 0;
    for (let i = 0; i < count; i += 1) {
        const note = first + i;
        if (!BLACK_OFFSETS[note % 12]) {
            whiteIndex += 1;
            continue;
        }
        const key = document.createElement('div');
        key.className = 'key black';
        key.dataset.note = String(note);
        key.style.left = `calc(${whiteIndex * whiteWidth}% - 2.1%)`;
        key.style.width = '4.2%';
        ui.keyboard.append(key);
        keyElements.set(note, key);
    }
}

function pointerNote(event) {
    const note = Number(event.target?.dataset?.note);
    return Number.isFinite(note) && note > 0 ? note : null;
}

ui.keyboard.addEventListener('pointerdown', (event) => {
    const note = pointerNote(event);
    if (note === null) return;
    event.target.setPointerCapture?.(event.pointerId);
    noteOn(note);
});
ui.keyboard.addEventListener('pointerup', (event) => {
    const note = pointerNote(event);
    if (note !== null) noteOff(note);
});
ui.keyboard.addEventListener('pointerleave', () => {
    for (const note of [...held]) noteOff(note);
});

window.addEventListener('keydown', (event) => {
    if (event.repeat || event.target instanceof HTMLTextAreaElement) {
        return;
    }
    // Text fields keep their keys — but a slider is not a text field. Blocking on any
    // focused input meant that after adjusting a knob, the next note played on the
    // keyboard was silently eaten.
    if (event.target instanceof HTMLInputElement && event.target.type !== 'range') {
        return;
    }
    if (event.key === 'z') { octave = Math.max(0, octave - 1); buildKeyboard(); return; }
    if (event.key === 'x') { octave = Math.min(7, octave + 1); buildKeyboard(); return; }
    const offset = KEY_MAP[event.key];
    if (offset !== undefined) noteOn(octave * 12 + 12 + offset);
});
window.addEventListener('keyup', (event) => {
    const offset = KEY_MAP[event.key];
    if (offset !== undefined) noteOff(octave * 12 + 12 + offset);
});

async function connectMidi() {
    if (!navigator.requestMIDIAccess) {
        ui.midiStatus.textContent = ' No Web MIDI in this browser.';
        return;
    }
    try {
        const access = await navigator.requestMIDIAccess();
        const attach = () => {
            const names = [];
            for (const input of access.inputs.values()) {
                names.push(input.name);
                input.onmidimessage = ({ data }) => {
                    const command = data[0] & 0xf0;
                    if (command === 0x90 && data[2] > 0) {
                        engine.noteOn(data[1], data[2] / 127);
                        keyElements.get(data[1])?.classList.add('held');
                    } else if (command === 0x80 || (command === 0x90 && data[2] === 0)) {
                        engine.noteOff(data[1]);
                        keyElements.get(data[1])?.classList.remove('held');
                    }
                };
            }
            ui.midiStatus.textContent = names.length
                ? ` MIDI: ${names.join(', ')}.`
                : ' No MIDI devices found.';
        };
        access.onstatechange = attach;
        attach();
    } catch {
        ui.midiStatus.textContent = ' MIDI access was declined.';
    }
}

// ---------------------------------------------------------------------------------
// Patch handling
// ---------------------------------------------------------------------------------

function applyPatch() {
    const result = validateCurrentText();
    if (!result?.ok) {
        ui.status.textContent = 'patch has errors';
        return;
    }
    currentPatch = JSON.parse(ui.patch.value);
    if (started) {
        engine.loadPatch(ui.patch.value);
    }
    buildControls(currentPatch);
}

async function loadExample(path) {
    const response = await fetch(path);
    const text = await response.text();
    ui.patch.value = text.trimEnd();
    applyPatch();
}

ui.apply.addEventListener('click', applyPatch);

ui.save.addEventListener('click', () => {
    const blob = new Blob([ui.patch.value], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    const name = currentPatch?.metadata?.name ?? 'patch';
    link.href = url;
    link.download = `${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}.json`;
    link.click();
    URL.revokeObjectURL(url);
});

ui.open.addEventListener('change', async (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    ui.patch.value = (await file.text()).trimEnd();
    applyPatch();
    event.target.value = '';
});

ui.examples.addEventListener('change', () => {
    loadExample(ui.examples.value);
    // A focused <select> turns letter keys into type-ahead option changes, which would
    // swap the patch mid-performance.
    ui.examples.blur();
});

// Buttons hold focus after a click too, where Enter would re-trigger them.
for (const button of [ui.apply, ui.save, ui.start]) {
    button.addEventListener('click', () => button.blur());
}

let validateTimer = 0;
ui.patch.addEventListener('input', () => {
    clearTimeout(validateTimer);
    validateTimer = setTimeout(validateCurrentText, 250);
});

ui.start.addEventListener('click', async () => {
    ui.start.disabled = true;
    try {
        await engine.start();
        started = true;
        engine.loadPatch(ui.patch.value);
        buildControls(currentPatch ?? JSON.parse(ui.patch.value));
        ui.start.textContent = 'Audio running';
        connectMidi();
    } catch (error) {
        ui.status.textContent = String(error.message ?? error);
        ui.start.disabled = false;
    }
});

engine.addEventListener('loaded', (event) => {
    const { ok, diagnostics, info } = event.detail;
    renderDiagnostics(diagnostics, { valid: ok });
    renderInfo(info);
    ui.status.textContent = ok ? 'playing' : 'patch has errors';
});

engine.addEventListener('meter', (event) => {
    const peak = event.detail;
    ui.meterFill.style.width = `${Math.min(100, peak * 100)}%`;
    ui.meterFill.classList.toggle('hot', peak > 0.99);
});

engine.addEventListener('engineerror', (event) => {
    ui.status.textContent = `engine: ${event.detail}`;
});

// ---------------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------------

async function boot() {
    for (const example of EXAMPLES) {
        const option = document.createElement('option');
        option.value = example.path;
        option.textContent = example.label;
        ui.examples.append(option);
    }
    buildKeyboard();

    try {
        const tooling = await engine.loadModule();
        ui.status.textContent = `schema v${tooling.schemaVersion}, block ${tooling.blockSize}`;
        await loadExample(EXAMPLES[0].path);
    } catch (error) {
        ui.status.textContent = String(error.message ?? error);
        ui.start.disabled = true;
    }
}

boot();
