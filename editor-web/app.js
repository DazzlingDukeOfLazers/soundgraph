// SoundGraph web host — the reference frontend.
//
// This is deliberately the plain one. It exists so there is a lightweight, zero-install
// way in, and so the Godot editor has something to be checked against: both open the same
// file and must mean the same thing by it.
//
// Nothing here knows any DSP. Controls are generated from the patch's own control
// surfaces, the picture is generated from the patch's own nodes and cables, and every
// diagnostic shown comes from the same validator the command line tools use.
import { SoundGraph } from './soundgraph.js';
import { GraphView } from './graph-view.js';
import { Onboarding } from './onboarding.js';
import { MILESTONES, flushFunnel, loadBuildStamp, milestone } from './reporting.js';
import {
    forgetEverything,
    handOffPatch,
    onboardingProgress,
    savePatchLocally,
    savedPatch,
} from './local-store.js';
import { SURFACES, isReachable, surface } from './surfaces.js';

const engine = new SoundGraph();

// Exposed on purpose. The console is the fastest way to poke at a running graph, and the
// differential testing against the Godot editor will want a handle on this too.
window.soundgraph = engine;

const ui = {
    start: document.getElementById('start'),
    deploy: document.getElementById('deploy'),
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
    graph: document.getElementById('graph'),
    graphName: document.getElementById('graph-name'),
    newPatch: document.getElementById('new-patch'),
    saveLocal: document.getElementById('save-local'),
    openFull: document.getElementById('open-full'),
    source: document.getElementById('source'),
    help: document.getElementById('help'),
    about: document.getElementById('about'),
    join: document.getElementById('join'),
    aboutSheet: document.getElementById('about-sheet'),
    helpSheet: document.getElementById('help-sheet'),
};

// The patch the introduction teaches. Named here rather than in the tour, because the page
// also offers it in the menu and a second spelling of the path is a second thing to keep
// in step.
const TUTORIAL_PATCH = '../examples/patches/start-here.json';

// A short, curated menu rather than all 280. The Godot editor scans the corpus, which is
// the right answer for an editor; a first visit wants five good ones and a way out.
const EXAMPLES = [
    { label: 'Start Here', path: TUTORIAL_PATCH },
    { label: 'First Synth', path: '../examples/patches/first-synth.json' },
    { label: 'Plucked String', path: '../examples/patches/plucked-string.json' },
    { label: 'Delay Echo', path: '../examples/patches/delay-echo.json' },
    { label: 'Poly Five', path: '../examples/patches/synths/poly-five.json' },
    { label: 'Acid Bass', path: '../examples/patches/synths/acid-bass.json' },
    { label: 'Warehouse', path: '../examples/patches/warehouse.json' },
    { label: '808 Kit', path: '../examples/patches/drums/kit.json' },
];

// What "New patch" means: the smallest thing that is still a patch and still makes a
// sound. An empty canvas is a worse starting point than one cable.
const NEW_PATCH = {
    schema_version: 1,
    metadata: { name: 'New Patch', description: 'One oscillator, straight to the output.' },
    nodes: [
        { id: 'osc', type: 'SawOscillator', name: 'Oscillator',
          parameters: { frequency: 220 }, position: { x: 0, y: 0 } },
        { id: 'out', type: 'Output', host: 'stereo', name: 'Output',
          parameters: { level: 0.4, safety_limit: 1 }, position: { x: 440, y: 0 } },
    ],
    connections: [
        { from: { node: 'osc', port: 'out' }, to: { node: 'out', port: 'left' } },
        { from: { node: 'osc', port: 'out' }, to: { node: 'out', port: 'right' } },
    ],
    controls: [
        { id: 'pitch', label: 'Pitch', kind: 'knob',
          target: { node: 'osc', parameter: 'frequency' },
          min: 40, max: 2000, default: 220, scaling: 'exponential' },
        { id: 'master', label: 'Master', kind: 'knob',
          target: { node: 'out', parameter: 'level' },
          min: 0, max: 1.2, default: 0.4, scaling: 'logarithmic' },
    ],
};

const graph = new GraphView(ui.graph);

// Exposed for the same reason the engine is: the console is where you check what the page
// thinks the graph looks like, and a picture that can only be inspected by squinting at it
// is a picture nothing can be asserted about.
window.soundgraphView = graph;

let started = false;
let currentPatch = null;

// Control id -> everything needed to read or move that control from outside the panel.
// The tour drives one of these; so does anything else that wants to move a knob without
// knowing how the panel is built.
const controlSurfaces = new Map();

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
    controlSurfaces.clear();
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

        const surface = {
            control,
            slider,
            value: initial,
            // Moving a control from code has to look identical to moving it by hand,
            // including to anything listening — the tour compares two values by calling
            // this, and a comparison you cannot hear is not a comparison.
            set(next) {
                surface.value = next;
                slider.value = String(Math.min(1, Math.max(0, toPosition(control, next))));
                readout.textContent = format(next);
                engine.setParameter(node, parameter, next);
                graph.setActive(node);
            },
        };

        slider.addEventListener('input', () => {
            const value = toValue(control, Number(slider.value));
            surface.value = value;
            readout.textContent = format(value);
            engine.setParameter(node, parameter, value);
            // The point of the picture: the knob you are holding lights the node it drives.
            graph.setActive(node);
            milestone(MILESTONES.FIRST_PARAMETER_CHANGED);
        });
        // Release focus when the drag ends, so arrow keys go back to being arrow keys
        // instead of nudging the last-touched knob.
        slider.addEventListener('pointerup', () => slider.blur());

        wrapper.append(label, slider, target);
        ui.controls.append(wrapper);
        controlSurfaces.set(control.id, surface);
    }
}

function findParameterValue(patch, nodeId, parameterName) {
    const node = (patch.nodes ?? []).find((candidate) => candidate.id === nodeId);
    return node?.parameters?.[parameterName];
}

/**
 * The patch as it currently sounds, not as it was loaded.
 *
 * Moving a control sends a value to the engine; it does not rewrite the document. So
 * anything that takes the patch elsewhere — saving it, downloading it, handing it to the
 * full editor — was carrying the values the file arrived with and silently discarding
 * every knob the visitor had moved. The golden moment IS a knob move, so handing that off
 * reverted is the one thing this page must not do.
 *
 * Built from the text rather than from `currentPatch`, so unapplied edits in the source
 * pane are not thrown away either. Text that does not parse is returned untouched: it is
 * the visitor's work, and mangling it to add parameters would be a worse trade than
 * saving it exactly as they left it.
 */
function patchWithControlValues() {
    let patch;
    try {
        patch = JSON.parse(ui.patch.value);
    } catch {
        return ui.patch.value;
    }
    for (const surface of controlSurfaces.values()) {
        const { node, parameter } = surface.control.target;
        const target = (patch.nodes ?? []).find((candidate) => candidate.id === node);
        if (!target) continue;
        target.parameters = target.parameters ?? {};
        target.parameters[parameter] = surface.value;
    }
    return JSON.stringify(patch, null, 2);
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

function noteName(note) {
    return `${NOTE_NAMES[note % 12]}${Math.floor(note / 12) - 1}`;
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
        // Buttons, not divs: a div piano is invisible to assistive tech and
        // untabbable, and this page is meant to be the zero-install doorway
        // for everyone who scans the QR — not everyone who can use a mouse.
        const key = document.createElement('button');
        key.type = 'button';
        key.className = 'key';
        key.dataset.note = String(note);
        key.setAttribute('aria-label', noteName(note));
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
        const key = document.createElement('button');
        key.type = 'button';
        key.className = 'key black';
        key.dataset.note = String(note);
        key.setAttribute('aria-label', noteName(note));
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
    // The picture is drawn from whatever parses, even when validation objects: a patch
    // with a bad cable is exactly when seeing the cables helps most. It is only refused
    // when the text is not JSON at all, because then there is nothing to draw.
    let parsed = null;
    try {
        parsed = JSON.parse(ui.patch.value);
    } catch {
        parsed = null;
    }
    if (parsed) {
        currentPatch = parsed;
        graph.render(parsed);
        ui.graphName.textContent = parsed.metadata?.name ?? '';
    }
    if (!result?.ok) {
        // Only the validator may call a patch broken. With no module loaded there is no
        // validator, and saying "patch has errors" there blames the file for the engine
        // having failed to arrive — which sends anybody debugging it to the wrong place.
        if (engine.tooling) {
            ui.status.textContent = 'patch has errors';
        }
        return;
    }
    if (started) {
        engine.loadPatch(ui.patch.value);
    }
    buildControls(currentPatch);
}

function setPatchText(text) {
    ui.patch.value = text.trimEnd();
    // A textarea keeps its scroll position when its value is replaced, so
    // without this a freshly loaded patch opens wherever the previous one
    // happened to be — mid-file, looking like the top.
    ui.patch.scrollTop = 0;
    applyPatch();
}

async function loadExample(path) {
    const response = await fetch(path);
    setPatchText(await response.text());
}

ui.apply.addEventListener('click', applyPatch);

ui.save.addEventListener('click', () => {
    const blob = new Blob([patchWithControlValues()], { type: 'application/json' });
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
    setPatchText(await file.text());
    event.target.value = '';
});

ui.examples.addEventListener('change', () => {
    loadExample(ui.examples.value);
    // "Second" means a different one. Re-picking the patch the tour taught is not the
    // thing this measure is asking about.
    if (ui.examples.value !== TUTORIAL_PATCH) {
        milestone(MILESTONES.SECOND_PATCH_LOADED);
    }
    // A focused <select> turns letter keys into type-ahead option changes, which would
    // swap the patch mid-performance.
    ui.examples.blur();
});

ui.newPatch.addEventListener('click', () => {
    setPatchText(JSON.stringify(NEW_PATCH, null, 2));
    ui.newPatch.blur();
});

function saveLocally() {
    const ok = savePatchLocally(patchWithControlValues(), currentPatch?.metadata?.name);
    ui.status.textContent = ok ? 'saved in this browser' : 'this browser refused to store it';
    if (ok) milestone(MILESTONES.PATCH_SAVED);
    return ok;
}

ui.saveLocal.addEventListener('click', () => {
    saveLocally();
    ui.saveLocal.blur();
});

// Selecting a node finds it in the patch text. The picture and the JSON are two views of
// one document, and moving between them by hand means scrolling and counting braces.
graph.addEventListener('nodeselect', (event) => {
    const id = event.detail;
    const needle = `"id": "${id}"`;
    const at = ui.patch.value.indexOf(needle);
    if (at < 0) return;
    // The source is collapsed by default, and selecting into a closed <details> selects
    // into something nobody can see.
    ui.source.open = true;
    ui.patch.focus();
    ui.patch.setSelectionRange(at, at + needle.length);
    // setSelectionRange scrolls the caret into view only in some browsers; this is the part
    // that reliably moves the box. The line height is read rather than assumed — a
    // hardcoded one silently stops pointing at the right line the day the CSS changes.
    const line = parseFloat(getComputedStyle(ui.patch).lineHeight) || 19;
    const before = ui.patch.value.slice(0, at).split('\n').length;
    ui.patch.scrollTop = Math.max(0, (before - 4) * line);
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

async function startAudio() {
    ui.start.disabled = true;
    try {
        await engine.start();
        started = true;
        engine.loadPatch(ui.patch.value);
        buildControls(currentPatch ?? JSON.parse(ui.patch.value));
        ui.start.textContent = 'Audio running';
        milestone(MILESTONES.AUDIO_STARTED);
        // Start pulling the full editor's files now, while the visitor plays. Pressing
        // Start is the intent gesture: the tour that follows runs a minute or two, which
        // is exactly the window a background prefetch needs, so by the time the tour's
        // last step points at the editor it opens warm. The metered-connection guards
        // inside warmFullEditor still apply.
        warmFullEditor();
        connectMidi();
    } catch (error) {
        ui.status.textContent = String(error.message ?? error);
        ui.start.disabled = false;
        throw error;
    }
}

ui.start.addEventListener('click', () => {
    startAudio().catch(() => {});
    // The second way to earn the "whole instrument" pointer: half a minute of actually
    // listening. Anyone still here at thirty seconds is not a bounce.
    setTimeout(() => earnAffordance(), 30000);
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
// The structural lesson
//
// One edit, performed on the patch document rather than mimed at it: the filter comes out
// of the audio path and the oscillator reaches the amplifier directly. The filter node
// stays where it is with nothing running through it, which is the part worth seeing — a
// bypass is a rewire, not a mute.
// ---------------------------------------------------------------------------------

let connectionsBeforeBypass = null;

function setBypass(on) {
    if (!currentPatch) return false;

    if (!on) {
        if (!connectionsBeforeBypass) return false;
        currentPatch.connections = connectionsBeforeBypass;
        connectionsBeforeBypass = null;
    } else {
        const connections = currentPatch.connections ?? [];
        const intoFilter = connections.find((c) => c.to.node === 'filter' && c.to.port === 'in');
        const outOfFilter = connections.find((c) => c.from.node === 'filter');
        if (!intoFilter || !outOfFilter) return false;

        connectionsBeforeBypass = connections;
        currentPatch.connections = connections
            .filter((c) => c !== intoFilter && c !== outOfFilter)
            .concat([{ from: intoFilter.from, to: outOfFilter.to }]);
    }

    setPatchText(JSON.stringify(currentPatch, null, 2));
    return true;
}

// ---------------------------------------------------------------------------------
// The other two surfaces
//
// The complaint that started this: the doorway gave no sign there was a building behind
// it. A surface with no URL configured is still announced — it says what it is and that it
// is not ready — because "we have not deployed it yet" is information, and a link that
// 404s is not.
// ---------------------------------------------------------------------------------

function renderSurfaces() {
    const list = document.getElementById('surfaces');
    list.replaceChildren();

    for (const entry of SURFACES) {
        const item = document.createElement('li');
        if (entry.here) item.className = 'here';

        const name = document.createElement('div');
        name.className = 'surface-name';
        name.append(document.createTextNode(entry.name));

        const badge = document.createElement('span');
        if (entry.here) {
            badge.className = 'badge';
            badge.textContent = 'you are here';
        } else if (!isReachable(entry.id)) {
            badge.className = 'badge pending';
            badge.textContent = 'not yet';
        }
        if (badge.textContent) name.append(badge);
        item.append(name);

        const summary = document.createElement('p');
        summary.textContent = entry.summary;
        item.append(summary);

        if (entry.cost) {
            const cost = document.createElement('p');
            cost.className = 'cost';
            cost.textContent = entry.cost;
            item.append(cost);
        }

        if (!entry.here && isReachable(entry.id)) {
            const link = document.createElement('a');
            link.href = entry.url;
            link.textContent = entry.id === 'desktop' ? 'Download' : 'Open this patch there';
            if (entry.id === 'full') {
                link.addEventListener('click', (event) => {
                    event.preventDefault();
                    openFullEditor();
                });
            }
            item.append(link);
        }
        list.append(item);
    }

    // The same list inside About, without the marketing voice.
    const about = document.getElementById('about-surfaces');
    about.replaceChildren();
    for (const entry of SURFACES) {
        const line = document.createElement('li');
        line.textContent = `${entry.name} — ${entry.detail}` +
            (entry.here ? ' You are using it now.' : isReachable(entry.id) ? '' : ' Not deployed yet.');
        about.append(line);
    }
}

/**
 * Carry the current patch to the full editor.
 *
 * The patch is the whole interchange: both surfaces read the same file and get every
 * answer about it from the same core, so "open it there" needs no protocol beyond leaving
 * the document somewhere both can see. Same origin, so localStorage is that somewhere.
 */
function openFullEditor() {
    const full = surface('full');
    if (!isReachable('full')) return false;
    handOffPatch(patchWithControlValues(), currentPatch?.metadata?.name);
    window.location.href = full.url;
    return true;
}

/**
 * Warm the full editor's big files once somebody has shown they want it.
 *
 * Only after a deliberate gesture — starting audio, or the golden moment for a visitor
 * who came in another way — and never against a metered connection: ten megabytes
 * fetched speculatively onto somebody's phone data is a cost they did not agree to. The
 * file list is empty until it is configured — see surfaces.js for why guessing the names
 * would produce a prefetch that fetches nothing while looking like it worked.
 *
 * Fetched by hand rather than with <link rel="prefetch"> because a prefetch is mute: the
 * "Open in the full editor" button doubles as the load meter, and a meter needs bytes to
 * count. Reading each response to the end is what lands it in the HTTP cache; the files
 * come one at a time, biggest first, at low priority, so the pull stays behind the
 * page's own traffic. Progress is decoded bytes against the sizes surfaces.js measured
 * off the export — approximate denominators, honest needle.
 */
let fullEditorWarmed = false;
let fullEditorWarming = false;

async function warmFullEditor() {
    if (fullEditorWarmed || fullEditorWarming) return true;
    const full = surface('full');
    if (!isReachable('full') || !full.preload?.length) return false;

    const connection = navigator.connection;
    if (connection?.saveData) return false;
    if (/(^|-)2g$/.test(connection?.effectiveType ?? '')) return false;

    fullEditorWarming = true;
    const base = new URL(full.url, window.location.href);
    const total = full.preload.reduce((sum, entry) => sum + entry.bytes, 0);
    let received = 0;
    paintEditorWarmth(0);
    try {
        for (const entry of full.preload) {
            const response = await fetch(new URL(entry.file, base), { priority: 'low' });
            if (!response.ok) throw new Error(`${entry.file}: ${response.status}`);
            if (response.body) {
                const reader = response.body.getReader();
                for (;;) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    received += value.length;
                    paintEditorWarmth(Math.min(received / total, 0.999));
                }
            } else {
                await response.arrayBuffer();
                received += entry.bytes;
                paintEditorWarmth(Math.min(received / total, 0.999));
            }
        }
    } catch {
        // A failed pull is not a failed page: the button goes back to its plain self and
        // the golden-moment backstop may try again later.
        fullEditorWarming = false;
        paintEditorWarmth(null);
        return false;
    }
    fullEditorWarmed = true;
    fullEditorWarming = false;
    paintEditorWarmth(1);
    return true;
}

// ---------------------------------------------------------------------------------
// The button is the meter.
//
// While the editor's files stream in, "Open in the full editor" fills left to right and
// counts, and when everything is cached it turns shiny with a slow pulse — the door
// changing from "exists" to "ready". The button stays clickable throughout: opening
// mid-pull just streams the remainder the ordinary way.
// ---------------------------------------------------------------------------------

let editorLoadNote = null;
let editorLoadShown = -1;

function paintEditorWarmth(fraction) {
    const trigger = ui.openFull;
    if (fraction === null) {
        trigger.classList.remove('loading', 'ready');
        trigger.style.removeProperty('--warmth');
        editorLoadNote?.remove();
        editorLoadNote = null;
        editorLoadShown = -1;
        return;
    }
    if (fraction >= 1) {
        trigger.classList.remove('loading');
        trigger.classList.add('ready');
        trigger.style.removeProperty('--warmth');
        editorLoadNote?.remove();
        editorLoadNote = null;
        return;
    }
    if (!editorLoadNote) {
        editorLoadNote = document.createElement('span');
        editorLoadNote.className = 'load-note';
        trigger.append(editorLoadNote);
    }
    trigger.classList.add('loading');
    trigger.style.setProperty('--warmth', String(fraction));
    // The text only changes when the integer does; the fill moves every chunk.
    const percent = Math.floor(fraction * 100);
    if (percent !== editorLoadShown) {
        editorLoadShown = percent;
        editorLoadNote.textContent = `${percent}%`;
    }
}

// ---------------------------------------------------------------------------------
// The introduction
// ---------------------------------------------------------------------------------

const tour = new Onboarding({
    graphElement: () => ui.graph,
    startAudio,
    audioRunning: () => started,
    // The worklet stops posting meter readings while the context is suspended, so the bar
    // holds whatever it last said — a frozen level reads as signal. Zero it on the way out.
    stopAudio: async () => {
        await engine.suspend();
        ui.meterFill.style.width = '0%';
        ui.meterFill.classList.remove('hot');
    },
    // Through start() rather than context.resume(), so resuming gets the same refusal
    // timeout as starting. A resume that never settles hangs just as silently.
    resumeAudio: () => engine.start(),
    loadTutorialPatch: () => loadExample(TUTORIAL_PATCH),
    controlElement: (id) => controlSurfaces.get(id)?.slider ?? null,
    controlValue: (id) => controlSurfaces.get(id)?.value ?? null,
    setControlValue: (id, value) => controlSurfaces.get(id)?.set(value),
    focusNodes: (ids) => graph.setFocus(ids),
    activeNode: (id) => graph.setActive(id),
    savePatchLocally: saveLocally,
    setBypass,
    fullEditor: () => (isReachable('full') ? surface('full') : null),
    fullEditorButton: () => ui.openFull,
    fullEditorWarmed: () => fullEditorWarmed,
    openFullEditor,
    // The backstop for a visitor who reached the golden moment without ever pressing
    // Start (audio started elsewhere, or a restart mid-session). Idempotent.
    onGoldenMoment: warmFullEditor,
});

ui.join.addEventListener('click', () => {
    tour.openMailingList();
    ui.join.blur();
});

// Only offered when there is somewhere to go.
if (isReachable('full')) {
    ui.openFull.hidden = false;
    ui.openFull.addEventListener('click', () => {
        ui.openFull.blur();
        openFullEditor();
    });
}

// ---------------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------------

function openSheet(sheet) {
    sheet.hidden = false;
    sheet.querySelector('button')?.focus();
}

function closeSheet(sheet) {
    sheet.hidden = true;
}

for (const [trigger, sheet] of [[ui.about, ui.aboutSheet], [ui.help, ui.helpSheet]]) {
    trigger.addEventListener('click', () => { openSheet(sheet); trigger.blur(); });
    // Clicking the backdrop closes; clicking the panel does not. Escape closes either.
    sheet.addEventListener('click', (event) => {
        if (event.target === sheet) closeSheet(sheet);
    });
}
// "Want the whole instrument?" appears exactly once, and only after the visitor has done
// the thing this page exists to let them do: held a route, or listened for a while. It is
// a pointer to the full editor, so it never appears anywhere the full editor is not
// deployed — an affordance that 404s would be worse than none.
const wholeInstrument = document.getElementById('whole-instrument');
let affordanceShown = false;
function earnAffordance() {
    if (affordanceShown || !isReachable('full')) return;
    affordanceShown = true;
    wholeInstrument.hidden = false;
}
graph.onRouteLocked = () => earnAffordance();
wholeInstrument.querySelector('a').addEventListener('click', (event) => {
    event.preventDefault();
    openFullEditor();
});

window.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    closeSheet(ui.aboutSheet);
    closeSheet(ui.helpSheet);
    // Escape also lets go of a locked route — the same gesture the desktop uses for
    // "never mind", and it costs nothing when no route is locked.
    graph.lockRoute(null);
});

document.getElementById('about-close').addEventListener('click', () => closeSheet(ui.aboutSheet));
document.getElementById('help-close').addEventListener('click', () => closeSheet(ui.helpSheet));
document.getElementById('about-join').addEventListener('click', () => {
    closeSheet(ui.aboutSheet);
    tour.openMailingList();
});
document.getElementById('project-join').addEventListener('click', () => tour.openMailingList());
document.getElementById('release-join').addEventListener('click', () => tour.openMailingList());
document.getElementById('help-restart').addEventListener('click', () => {
    closeSheet(ui.helpSheet);
    tour.restart();
});
document.getElementById('about-forget').addEventListener('click', () => {
    forgetEverything();
    ui.status.textContent = 'this browser has forgotten everything';
});

// ---------------------------------------------------------------------------------
// Deploy to hardware
//
// The demo's whole point, as one click: the patch in this page, over Web Serial, into
// the board's NVS. Speaks the same console protocol as tools/esp32/sg-serial.py —
// "load <n>" / SEND / bytes / OK — and shows the device's own diagnostics on failure,
// which are the same diagnostics this page shows, because they come from the same core.
// Chrome-only; the button simply does not exist elsewhere.
// ---------------------------------------------------------------------------------

const encoder = new TextEncoder();

async function deployToBoard() {
    const validation = validateCurrentText();
    if (!validation?.ok) {
        ui.status.textContent = 'fix the patch before deploying';
        return;
    }
    const payload = encoder.encode(ui.patch.value);

    let port;
    try {
        port = await navigator.serial.requestPort();
    } catch {
        return;  // chooser dismissed
    }

    ui.deploy.disabled = true;
    ui.status.textContent = 'deploying…';

    const serialDecoder = new TextDecoder();
    let received = '';
    let scanFrom = 0;
    let reader = null;
    let writer = null;

    const pumpDone = (async () => {
        // Background read pump: everything the board says accumulates in `received`.
        while (port.readable) {
            reader = port.readable.getReader();
            try {
                for (;;) {
                    const { value, done } = await reader.read();
                    if (done) return;
                    if (value) received += serialDecoder.decode(value, { stream: true });
                }
            } catch {
                return;  // port closed or unplugged
            } finally {
                reader.releaseLock();
            }
        }
    })();

    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    const waitQuiet = async (quietMs, limitMs) => {
        const start = performance.now();
        let lastLength = received.length;
        let lastChange = start;
        while (performance.now() - start < limitMs) {
            await sleep(50);
            if (received.length !== lastLength) {
                lastLength = received.length;
                lastChange = performance.now();
            } else if (performance.now() - lastChange > quietMs) {
                break;
            }
        }
        scanFrom = received.length;
    };

    const waitForLine = async (prefixes, timeoutMs) => {
        const start = performance.now();
        while (performance.now() - start < timeoutMs) {
            const lines = received.slice(scanFrom).split('\n');
            for (const raw of lines) {
                const line = raw.trim();
                for (const prefix of prefixes) {
                    if (line.startsWith(prefix)) {
                        scanFrom = received.length;
                        return line;
                    }
                }
            }
            await sleep(50);
        }
        return null;
    };

    try {
        await port.open({ baudRate: 115200 });
        writer = port.writable.getWriter();

        // Opening the port reset the board; let the boot chatter finish first.
        await waitQuiet(500, 6000);

        await writer.write(encoder.encode(`load ${payload.length}\n`));
        const sendLine = await waitForLine(['SEND', 'ERR'], 5000);
        if (!sendLine?.startsWith('SEND')) {
            throw new Error(sendLine ?? 'the board never answered — is something else using the port?');
        }

        await writer.write(payload);
        const answer = await waitForLine(['OK', 'ERR'], 30000);

        if (answer?.startsWith('OK')) {
            const name = currentPatch?.metadata?.name ?? 'patch';
            ui.status.textContent = `${name} is on the board`;
        } else if (answer?.startsWith('ERR [')) {
            // The board's build diagnostics, rendered exactly like local ones.
            renderDiagnostics(JSON.parse(answer.slice(4)), { valid: false });
            ui.status.textContent = 'the board rejected the patch';
        } else {
            throw new Error(answer ?? 'no reply to the upload');
        }
    } catch (error) {
        ui.status.textContent = `deploy failed: ${error.message ?? error}`;
    } finally {
        try { writer?.releaseLock(); } catch { /* already closed */ }
        try { await reader?.cancel(); } catch { /* already closed */ }
        await pumpDone;
        try { await port.close(); } catch { /* already closed */ }
        ui.deploy.disabled = false;
    }
}

if ('serial' in navigator) {
    ui.deploy.hidden = false;
    ui.deploy.addEventListener('click', () => {
        deployToBoard();
        ui.deploy.blur();
    });
}

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
    renderSurfaces();
    loadBuildStamp().then((stamp) => {
        document.getElementById('about-build').textContent = stamp;
    });

    const progress = onboardingProgress();
    const returning = progress.completed || progress.skipped;
    const stored = savedPatch();

    try {
        const tooling = await engine.loadModule();
        graph.setRegistry(tooling.registry());
        ui.status.textContent = `schema v${tooling.schemaVersion}, block ${tooling.blockSize}`;
    } catch (error) {
        // No module means no validation and no audio — but the patch still parses and the
        // picture still draws, and a page that shows the graph is worth more than a page
        // that shows an error. The Start button is what goes away.
        ui.status.textContent = String(error.message ?? error);
        ui.start.disabled = true;
    }

    // A returning visitor opens into their own patch, or a sensible default. A first-time
    // visitor opens into the one the introduction teaches.
    if (returning && stored) {
        setPatchText(stored.text);
        ui.graphName.textContent = `${stored.name} (saved here)`;
    } else {
        await loadExample(TUTORIAL_PATCH);
    }

    if (!progress.started) {
        tour.start();
    } else {
        tour.offerResume();
    }
}

// Anything the funnel collected during a visit that ends without any of the tour's own
// exits — a reload, a closed tab, a link away — still gets one row.
window.addEventListener('pagehide', () => { flushFunnel({ keepalive: true }); });

boot();
