// SoundGraph — the AudioWorklet processor.
//
// This file runs on the audio thread. AudioWorkletGlobalScope is a hostile little
// environment: no fetch, no module imports, no DOM, and nothing here may allocate or
// block once audio is running. So it does as little as possible — it instantiates the
// WebAssembly module the main thread compiled for it, and then only copies samples.
//
// Everything that decides what the patch sounds like is inside that module, and it is the
// same C++ that produced the native golden vectors.

// Enough for any render quantum a browser is likely to use. Buffers are allocated once,
// at load, and the module is built with a fixed heap so these views never detach.
const MAX_FRAMES = 1024;

// How often to report the output level back to the UI. Every block would flood the
// message port for no visible benefit.
const METER_INTERVAL_BLOCKS = 8;

class SoundGraphProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        this.exports = null;
        this.engine = 0;
        this.leftPointer = 0;
        this.rightPointer = 0;
        this.leftView = null;
        this.rightView = null;
        this.heap = null;
        this.blocksSinceMeter = 0;
        this.loaded = false;

        this.port.onmessage = (event) => {
            try {
                this.handle(event.data);
            } catch (error) {
                this.port.postMessage({ type: 'error', message: String(error && error.message || error) });
            }
        };
    }

    handle(message) {
        switch (message.type) {
            case 'init':
                return this.init(message.bytes);
            case 'load':
                return this.load(message.patch);
            case 'bindParameter':
                return this.bindParameter(message.id, message.node, message.parameter);
            case 'setParameter':
                if (this.engine) {
                    this.exports.sg_engine_set_parameter_by_handle(this.engine, message.handle, message.value);
                }
                return;
            case 'noteOn':
                if (this.engine) {
                    this.exports.sg_engine_note_on(this.engine, message.note, message.velocity);
                }
                return;
            case 'noteOff':
                if (this.engine) {
                    this.exports.sg_engine_note_off(this.engine, message.note);
                }
                return;
            case 'allNotesOff':
                if (this.engine) {
                    this.exports.sg_engine_all_notes_off(this.engine);
                }
                return;
            case 'reset':
                if (this.engine) {
                    this.exports.sg_engine_reset(this.engine);
                }
                return;
            default:
                return;
        }
    }

    // The module arrives as raw bytes and is compiled here.
    //
    // It would be nicer to compile once on the main thread and post the WebAssembly.Module
    // across — but an AudioWorkletGlobalScope is a separate agent cluster, so a Module
    // fails to structured-clone into it. The failure is silent: postMessage does not
    // throw and the message simply never arrives. Bytes clone fine, and synchronous
    // compilation is permitted off the main thread, so this happens once at start-up and
    // never on a rendering block.
    init(bytes) {
        const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
        this.exports = instance.exports;
        if (typeof this.exports._initialize === 'function') {
            this.exports._initialize();
        }

        this.heap = this.exports.memory.buffer;
        this.engine = this.exports.sg_engine_create(sampleRate);
        this.leftPointer = this.exports.malloc(MAX_FRAMES * 4);
        this.rightPointer = this.exports.malloc(MAX_FRAMES * 4);
        this.leftView = new Float32Array(this.heap, this.leftPointer, MAX_FRAMES);
        this.rightView = new Float32Array(this.heap, this.rightPointer, MAX_FRAMES);

        this.port.postMessage({
            type: 'ready',
            sampleRate: sampleRate,
            blockSize: this.exports.sg_block_size(),
            schemaVersion: this.exports.sg_schema_version(),
        });
    }

    // `patch` is UTF-8 bytes. The main thread encodes them, because TextEncoder is not
    // something an AudioWorkletGlobalScope can be relied on to have.
    load(patch) {
        if (!this.exports) {
            return;
        }
        const pointer = this.writeBytes(patch);
        const ok = this.exports.sg_engine_load_patch(this.engine, pointer) === 1;
        this.exports.free(pointer);

        const diagnostics = this.readBytes(this.exports.sg_engine_diagnostics(this.engine));
        const info = this.readBytes(this.exports.sg_engine_info(this.engine));
        this.loaded = ok;
        // Bytes go back as bytes; the main thread decodes them where TextDecoder lives.
        this.port.postMessage({ type: 'loaded', ok, diagnostics, info }, [diagnostics.buffer, info.buffer]);
    }

    bindParameter(id, node, parameter) {
        if (!this.exports || !this.engine) {
            return;
        }
        const nodePointer = this.writeBytes(node);
        const parameterPointer = this.writeBytes(parameter);
        const handle = this.exports.sg_engine_parameter_handle(this.engine, nodePointer, parameterPointer);
        this.exports.free(nodePointer);
        this.exports.free(parameterPointer);
        this.port.postMessage({ type: 'parameterBound', id, handle });
    }

    writeBytes(bytes) {
        const pointer = this.exports.malloc(bytes.length + 1);
        const view = new Uint8Array(this.heap, pointer, bytes.length + 1);
        view.set(bytes);
        view[bytes.length] = 0;
        return pointer;
    }

    readBytes(pointer) {
        const view = new Uint8Array(this.heap);
        let end = pointer;
        while (view[end] !== 0) {
            end += 1;
        }
        return view.slice(pointer, end);
    }

    process(inputs, outputs) {
        const output = outputs[0];
        if (!output || output.length === 0) {
            return true;
        }
        const frames = output[0].length;

        if (!this.loaded || frames > MAX_FRAMES) {
            for (let channel = 0; channel < output.length; channel += 1) {
                output[channel].fill(0);
            }
            return true;
        }

        this.exports.sg_engine_render(this.engine, this.leftPointer, this.rightPointer, frames);

        output[0].set(this.leftView.subarray(0, frames));
        if (output.length > 1) {
            output[1].set(this.rightView.subarray(0, frames));
        }

        this.blocksSinceMeter += 1;
        if (this.blocksSinceMeter >= METER_INTERVAL_BLOCKS) {
            this.blocksSinceMeter = 0;
            this.port.postMessage({ type: 'meter', peak: this.exports.sg_engine_peak(this.engine) });
        }

        return true;
    }
}

registerProcessor('soundgraph', SoundGraphProcessor);
