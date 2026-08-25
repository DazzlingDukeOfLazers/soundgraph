// SoundGraph — the main-thread half of the browser runtime.
//
// Owns the AudioContext and the worklet, and keeps a second instance of the same module
// for editor work: validating a patch and describing the node vocabulary. Those run here
// rather than on the audio thread so that typing in the editor can never stall audio.
//
// The DSP itself lives entirely in the worklet. Nothing in this file decides what a graph
// means.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// A module instance used only for editor-side questions: validation, the node palette.
// Kept separate from the audio engine so the two never contend.
class Tooling {
    constructor(instance) {
        this.exports = instance.exports;
        if (typeof this.exports._initialize === 'function') {
            this.exports._initialize();
        }
        this.heap = this.exports.memory.buffer;
    }

    get schemaVersion() {
        return this.exports.sg_schema_version();
    }

    get blockSize() {
        return this.exports.sg_block_size();
    }

    // The full node vocabulary: ports, types, ranges, categories, search terms.
    // The editor builds its palette from this rather than keeping its own copy, so a node
    // added to the core shows up here without any JavaScript changing.
    registry() {
        return JSON.parse(this.readString(this.exports.sg_registry_json()));
    }

    // Returns { ok, diagnostics: [...] }. Cheap enough to call on every edit.
    validate(patchText) {
        const pointer = this.writeString(patchText);
        const result = JSON.parse(this.readString(this.exports.sg_validate_patch(pointer)));
        this.exports.free(pointer);
        return result;
    }

    writeString(text) {
        const bytes = encoder.encode(text);
        const pointer = this.exports.malloc(bytes.length + 1);
        const view = new Uint8Array(this.heap, pointer, bytes.length + 1);
        view.set(bytes);
        view[bytes.length] = 0;
        return pointer;
    }

    readString(pointer) {
        const view = new Uint8Array(this.heap);
        let end = pointer;
        while (view[end] !== 0) {
            end += 1;
        }
        return decoder.decode(view.subarray(pointer, end));
    }
}

export class SoundGraph extends EventTarget {
    constructor() {
        super();
        this.context = null;
        this.node = null;
        this.module = null;
        this.tooling = null;
        this.ready = false;
        this.parameterHandles = new Map();
        this.pendingBinds = new Map();
        this.nextBindId = 1;
        // The in-flight start, if there is one. See start().
        this.starting = null;
    }

    // Fetches and compiles the module. Safe to call before any user gesture — no
    // AudioContext is created here, so nothing needs permission yet.
    async loadModule(url = './soundgraph.wasm') {
        try {
            const response = await fetch(url);
            if (!response.ok) {
                throw new Error(`could not fetch ${url} (${response.status})`);
            }
            // compileStreaming would be better, but it needs the right Content-Type and this
            // has to work off a plain static file server too.
            this.bytes = await response.arrayBuffer();
            this.module = await WebAssembly.compile(this.bytes);
            this.tooling = new Tooling(await WebAssembly.instantiate(this.module, {}));
            return this.tooling;
        } catch (error) {
            // Tagged, because `start()` can fail two ways that have nothing in common
            // except the silence: the module never arrived, or the browser would not give
            // us an AudioContext. Sending somebody to check their output device over a
            // missing download is sending them to the one place the answer is not.
            if (error instanceof Error) {
                error.kind = 'module';
            }
            throw error;
        }
    }

    /**
     * Resume, or say why not.
     *
     * `AudioContext.resume()` does NOT reject when the browser refuses to start audio — the
     * promise simply never settles. Awaiting it therefore waits forever, which upstream is
     * indistinguishable from a crash: no error, no rejection, nothing to catch, and a page
     * that sits there looking hung. A browser that has decided not to give you audio is a
     * normal thing to handle, so it is turned into an ordinary failure here.
     *
     * The state is checked as well as the race, because resolving is not the same as
     * running: a context can settle back into `suspended` and report success.
     */
    async resumeContext(timeoutMs = 5000) {
        if (this.context.state === 'running') {
            return;
        }
        let timer = 0;
        const expiry = new Promise((resolve) => {
            timer = setTimeout(() => resolve('timeout'), timeoutMs);
        });
        const outcome = await Promise.race([this.context.resume().then(() => 'resumed'), expiry]);
        clearTimeout(timer);

        if (outcome === 'timeout' || this.context.state !== 'running') {
            const error = new Error(
                outcome === 'timeout'
                    ? 'the browser never answered the request to start audio'
                    : `the browser would not start audio (the context is ${this.context.state})`);
            error.kind = 'audio';
            throw error;
        }
    }

    /**
     * Must be called from a user gesture: browsers will not start audio otherwise.
     *
     * SINGLE-FLIGHT, AND IT HAS TO BE. Two overlapping calls each used to build their own
     * AudioContext, worklet and graph, and each connected to the destination — the same
     * patch playing twice, slightly out of phase, with the first copy unstoppable because
     * only the last is remembered in `this.node`. Nothing downstream can recover from that;
     * even reloading the patch only reaches one of them.
     *
     * The window is real rather than theoretical: `this.context` is not assigned until
     * after `loadModule()` awaits, so a second caller arriving during that await sees a
     * blank instance and starts again from the top. A second call now joins the first.
     */
    async start(workletUrl = './soundgraph-worklet.js') {
        if (this.starting) {
            return this.starting;
        }
        this.starting = this.startOnce(workletUrl);
        try {
            return await this.starting;
        } finally {
            this.starting = null;
        }
    }

    async startOnce(workletUrl) {
        // Covers the resume case and, with the guard above, guarantees at most one node.
        if (this.context) {
            await this.resumeContext();
            return;
        }
        if (!this.module) {
            await this.loadModule();
        }

        this.context = new AudioContext();
        await this.context.audioWorklet.addModule(workletUrl);

        this.node = new AudioWorkletNode(this.context, 'soundgraph', {
            numberOfInputs: 0,
            numberOfOutputs: 1,
            outputChannelCount: [2],
        });
        this.node.port.onmessage = (event) => this.receive(event.data);
        this.node.connect(this.context.destination);

        // The worklet compiles its own copy. A WebAssembly.Module cannot be cloned into
        // an AudioWorkletGlobalScope — it is a separate agent cluster — and the attempt
        // fails silently, so the bytes go across instead. See soundgraph-worklet.js.
        // The buffer is copied rather than transferred so this survives a restart.
        this.node.port.postMessage({ type: 'init', bytes: this.bytes.slice(0) });
        await this.resumeContext();
    }

    receive(message) {
        switch (message.type) {
            case 'ready':
                this.ready = true;
                this.dispatchEvent(new CustomEvent('ready', { detail: message }));
                return;
            case 'loaded': {
                const detail = {
                    ok: message.ok,
                    diagnostics: JSON.parse(decoder.decode(message.diagnostics) || '[]'),
                    info: JSON.parse(decoder.decode(message.info) || '{}'),
                };
                this.dispatchEvent(new CustomEvent('loaded', { detail }));
                return;
            }
            case 'parameterBound': {
                const name = this.pendingBinds.get(message.id);
                this.pendingBinds.delete(message.id);
                if (name !== undefined && message.handle >= 0) {
                    this.parameterHandles.set(name, message.handle);
                }
                return;
            }
            case 'meter':
                this.dispatchEvent(new CustomEvent('meter', { detail: message.peak }));
                return;
            case 'error':
                this.dispatchEvent(new CustomEvent('engineerror', { detail: message.message }));
                return;
            default:
                return;
        }
    }

    loadPatch(patchText) {
        if (!this.node) {
            return;
        }
        this.parameterHandles.clear();
        this.pendingBinds.clear();
        const bytes = encoder.encode(patchText);
        this.node.port.postMessage({ type: 'load', patch: bytes }, [bytes.buffer]);
    }

    // Resolve a control once, then move it by handle. Keeps strings off the audio thread.
    bindParameter(nodeId, parameterName) {
        if (!this.node) {
            return;
        }
        const id = this.nextBindId++;
        this.pendingBinds.set(id, `${nodeId}.${parameterName}`);
        this.node.port.postMessage({
            type: 'bindParameter',
            id,
            node: encoder.encode(nodeId),
            parameter: encoder.encode(parameterName),
        });
    }

    setParameter(nodeId, parameterName, value) {
        const handle = this.parameterHandles.get(`${nodeId}.${parameterName}`);
        if (handle === undefined || !this.node) {
            return false;
        }
        this.node.port.postMessage({ type: 'setParameter', handle, value });
        return true;
    }

    noteOn(note, velocity = 0.9) {
        this.node?.port.postMessage({ type: 'noteOn', note, velocity });
    }

    noteOff(note) {
        this.node?.port.postMessage({ type: 'noteOff', note });
    }

    allNotesOff() {
        this.node?.port.postMessage({ type: 'allNotesOff' });
    }

    reset() {
        this.node?.port.postMessage({ type: 'reset' });
    }

    async suspend() {
        await this.context?.suspend();
    }
}
