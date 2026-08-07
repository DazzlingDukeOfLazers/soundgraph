// Milestone B's exit condition: does the browser build sound like the native build?
//
// Renders every case in tests/golden/cases.json through the WebAssembly module and
// compares it against the vectors the native build recorded. Same patches, same events,
// same tolerance — the only thing that differs is which compiler produced the code.
//
//   node runtime-wasm/verify-goldens.mjs [path/to/soundgraph.wasm]
//
// Exits non-zero if any case drifts, so it can be a build step.
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');
const goldenDir = join(repoRoot, 'tests', 'golden');

// Matches the native tolerance in tests/test_golden.cpp. Cross-target expectations live
// in docs/test-matrix.md: a difference bigger than this is a semantic difference, not a
// floating-point one.
const TOLERANCE = 1.0e-5;

const wasmPath = process.argv[2] || join(repoRoot, 'build-wasm', 'bin', 'soundgraph.wasm');
const BLOCK = 64;

function readFloatWav(path) {
    const bytes = readFileSync(path);
    if (bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') {
        throw new Error(`${path} is not a WAV file`);
    }

    let position = 12;
    let format = 0;
    let bits = 0;
    let sampleRate = 0;

    while (position + 8 <= bytes.length) {
        const id = bytes.toString('ascii', position, position + 4);
        const size = bytes.readUInt32LE(position + 4);
        const body = position + 8;

        if (id === 'fmt ') {
            format = bytes.readUInt16LE(body);
            sampleRate = bytes.readUInt32LE(body + 4);
            bits = bytes.readUInt16LE(body + 14);
        } else if (id === 'data') {
            if (format !== 3 || bits !== 32) {
                throw new Error(`${path}: expected 32-bit float PCM, got format ${format}/${bits}`);
            }
            const count = size / 4;
            const samples = new Float32Array(count);
            for (let i = 0; i < count; i += 1) {
                samples[i] = bytes.readFloatLE(body + i * 4);
            }
            return { sampleRate, samples };
        }
        position = body + size + (size & 1);
    }
    throw new Error(`${path}: no data chunk`);
}

class WasmEngine {
    constructor(exports, sampleRate) {
        this.x = exports;
        this.heap = exports.memory.buffer;
        this.engine = exports.sg_engine_create(sampleRate);
        this.maxFrames = 1024;
        this.leftPointer = exports.malloc(this.maxFrames * 4);
        this.rightPointer = exports.malloc(this.maxFrames * 4);
        this.leftView = new Float32Array(this.heap, this.leftPointer, this.maxFrames);
    }

    writeString(text) {
        const bytes = Buffer.from(text, 'utf8');
        const pointer = this.x.malloc(bytes.length + 1);
        const view = new Uint8Array(this.heap, pointer, bytes.length + 1);
        view.set(bytes);
        view[bytes.length] = 0;
        return pointer;
    }

    readString(pointer) {
        const view = new Uint8Array(this.heap);
        let end = pointer;
        while (view[end] !== 0) end += 1;
        return Buffer.from(view.subarray(pointer, end)).toString('utf8');
    }

    loadPatch(text) {
        const pointer = this.writeString(text);
        const ok = this.x.sg_engine_load_patch(this.engine, pointer) === 1;
        this.x.free(pointer);
        return { ok, diagnostics: JSON.parse(this.readString(this.x.sg_engine_diagnostics(this.engine))) };
    }

    render(frames) {
        this.x.sg_engine_render(this.engine, this.leftPointer, this.rightPointer, frames);
        return this.leftView.subarray(0, frames);
    }
}

async function main() {
    const moduleBytes = readFileSync(wasmPath);
    const module = await WebAssembly.compile(moduleBytes);

    const manifest = JSON.parse(readFileSync(join(goldenDir, 'cases.json'), 'utf8'));
    const sampleRate = manifest.sample_rate || 48000;

    console.log(`soundgraph.wasm  ${(moduleBytes.length / 1024).toFixed(1)} KB`);
    console.log(`comparing ${manifest.cases.length} golden cases at ${sampleRate} Hz, tolerance ${TOLERANCE}\n`);

    let failures = 0;

    for (const item of manifest.cases) {
        const instance = await WebAssembly.instantiate(module, {});
        if (typeof instance.exports._initialize === 'function') {
            instance.exports._initialize();
        }
        const engine = new WasmEngine(instance.exports, sampleRate);

        const patchText = readFileSync(join(goldenDir, item.patch), 'utf8');
        const loaded = engine.loadPatch(patchText);
        if (!loaded.ok) {
            console.log(`  FAIL ${item.name}: patch did not build`);
            for (const diagnostic of loaded.diagnostics) {
                console.log(`         ${diagnostic.severity}: ${diagnostic.message}`);
            }
            failures += 1;
            continue;
        }

        const output = new Float32Array(item.frames);
        const events = (item.events || []).slice();
        let nextEvent = 0;
        let position = 0;

        // Identical scheduling to the native runner: events land on the block that
        // contains their frame.
        while (position < item.frames) {
            const frames = Math.min(BLOCK, item.frames - position);
            while (nextEvent < events.length && events[nextEvent].frame < position + frames) {
                const event = events[nextEvent];
                if (event.type === 'note_on') {
                    instance.exports.sg_engine_note_on(engine.engine, event.note, event.velocity ?? 1.0);
                } else {
                    instance.exports.sg_engine_note_off(engine.engine, event.note);
                }
                nextEvent += 1;
            }
            output.set(engine.render(frames), position);
            position += frames;
        }

        const expected = readFloatWav(join(goldenDir, 'vectors', `${item.name}.wav`));
        if (expected.samples.length !== output.length) {
            console.log(`  FAIL ${item.name}: expected ${expected.samples.length} samples, produced ${output.length}`);
            failures += 1;
            continue;
        }

        let worst = 0;
        let worstIndex = 0;
        for (let i = 0; i < output.length; i += 1) {
            const difference = Math.abs(expected.samples[i] - output[i]);
            if (difference > worst) {
                worst = difference;
                worstIndex = i;
            }
        }

        const exact = worst === 0;
        const passed = worst <= TOLERANCE;
        if (!passed) failures += 1;

        const label = passed ? (exact ? 'exact' : 'ok   ') : 'FAIL ';
        console.log(
            `  ${label} ${item.name.padEnd(16)} max difference ${worst.toExponential(2)}` +
            (worst > 0 ? ` at sample ${worstIndex}` : ''),
        );
    }

    console.log('');
    if (failures > 0) {
        console.log(`${failures} of ${manifest.cases.length} cases differ from the native vectors.`);
        process.exit(1);
    }
    console.log(`All ${manifest.cases.length} cases match the native vectors within ${TOLERANCE}.`);
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
