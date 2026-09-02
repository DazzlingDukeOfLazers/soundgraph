// A read-only picture of the patch.
//
// The page had every fact about a graph and no way to see one: execution order as a line
// of text, controls that named `filter.cutoff` without saying where that was. This draws
// the nodes and the cables between them, so "the filter" is a thing on screen you can
// point at rather than a word in a label.
//
// It is deliberately NOT an editor. Nothing here adds, removes or rewires anything — that
// is the Godot editor's job, and a second program with opinions about what a graph means
// is exactly what this repository is arranged to avoid. This one only reflects the patch
// it was handed.
//
// Signal types follow docs/UX_PRINCIPLES.md: audio is a strong solid line, control is
// lighter and thinner, event and note are dashed. Never colour alone — the weight and the
// dash carry the same information for anyone who cannot separate the hues.

const SVG = 'http://www.w3.org/2000/svg';

// Graph units. Patch positions are authored on a 440x400 grid (see any file in
// examples/patches), so a box narrower than that spacing leaves room for cable.
const BOX_WIDTH = 360;
const BOX_HEIGHT = 190;
const PADDING = 90;

// Used when a patch omits `position`, which is legal — a position is an editor hint and
// a hand-written patch is entitled not to carry one.
const FALLBACK_X = 440;
const FALLBACK_Y = 400;

function element(name, attributes = {}) {
    const node = document.createElementNS(SVG, name);
    for (const [key, value] of Object.entries(attributes)) {
        node.setAttribute(key, String(value));
    }
    return node;
}

export class GraphView extends EventTarget {
    constructor(host) {
        super();
        this.host = host;
        this.patch = null;
        this.registry = null;
        this.boxes = new Map();   // node id -> {x, y, node}
        this.focused = null;      // Set of node ids, or null meaning "everything"
        this.route = null;        // hovered route family (a from-port key), or null
        this.lockedRoute = null;  // the same, made persistent by a click
        this.active = null;       // the node whose parameter a control is driving
        this.svg = null;
    }

    // The node vocabulary, once it is available. Without it the view still draws — it
    // just cannot tell an audio cable from a control one, and says so by drawing every
    // cable the same neutral way rather than guessing at a type it does not know.
    setRegistry(registry) {
        this.registry = registry;
        if (this.patch) {
            this.render(this.patch);
        }
    }

    typeOf(nodeId) {
        return this.boxes.get(nodeId)?.node?.type ?? null;
    }

    descriptor(typeName) {
        return this.registry?.types?.find((entry) => entry.name === typeName) ?? null;
    }

    label(node) {
        return node.name || node.type || node.id;
    }

    // -------------------------------------------------------------------------------
    // Layout
    //
    // Authored positions win. A patch arranged in an editor should look the same here —
    // that is the whole reason `position` lives in the patch format instead of in some
    // editor's own sidecar file.
    // -------------------------------------------------------------------------------

    layout(patch) {
        const nodes = patch.nodes ?? [];
        this.boxes.clear();

        // Depth from the sources, for nodes with no authored position. A cheap
        // longest-path relaxation rather than a real layered layout: this is a fallback
        // for hand-written patches, not a competitor to the editor's layout engine. It is
        // bounded by the node count so a feedback cycle cannot spin it forever.
        const depth = new Map(nodes.map((node) => [node.id, 0]));
        for (let pass = 0; pass < nodes.length; pass += 1) {
            let moved = false;
            for (const connection of patch.connections ?? []) {
                const from = depth.get(connection.from.node);
                const to = depth.get(connection.to.node);
                if (from === undefined || to === undefined) continue;
                if (to < from + 1) {
                    depth.set(connection.to.node, from + 1);
                    moved = true;
                }
            }
            if (!moved) break;
        }

        const perColumn = new Map();
        for (const node of nodes) {
            const column = depth.get(node.id) ?? 0;
            const row = perColumn.get(column) ?? 0;
            perColumn.set(column, row + 1);
            this.boxes.set(node.id, {
                node,
                x: node.position?.x ?? column * FALLBACK_X,
                y: node.position?.y ?? row * FALLBACK_Y,
            });
        }
    }

    // Where a cable leaves or enters a box. Ports are spread down the edge in the order
    // the registry declares them, so a node's second input is always in the same place. If
    // the anchors moved with whatever happened to be connected, the same node would draw
    // differently in two patches, and the picture would stop being learnable.
    anchor(nodeId, portName, side) {
        const box = this.boxes.get(nodeId);
        if (!box) return null;

        const descriptor = this.descriptor(box.node.type);
        const ports = (side === 'out' ? descriptor?.outputs : descriptor?.inputs) ?? [];
        let index = ports.findIndex((port) => port.name === portName);
        let count = ports.length;

        if (index < 0) {
            // No registry, or a port it does not know: fall back to the ports this patch
            // actually uses on this node, which at least keeps two cables off each other.
            const used = [...new Set(
                (this.patch?.connections ?? [])
                    .filter((c) => (side === 'out' ? c.from : c.to).node === nodeId)
                    .map((c) => (side === 'out' ? c.from : c.to).port)
            )].sort();
            index = Math.max(0, used.indexOf(portName));
            count = Math.max(1, used.length);
        }

        return {
            x: side === 'out' ? box.x + BOX_WIDTH : box.x,
            y: box.y + (BOX_HEIGHT * (index + 1)) / (count + 1),
        };
    }

    signalType(connection) {
        const descriptor = this.descriptor(this.typeOf(connection.from.node));
        const port = descriptor?.outputs?.find((entry) => entry.name === connection.from.port);
        return port?.type ?? 'unknown';
    }

    // -------------------------------------------------------------------------------
    // Drawing
    // -------------------------------------------------------------------------------

    render(patch) {
        this.patch = patch;
        this.host.replaceChildren();
        if (!patch?.nodes?.length) {
            return;
        }
        this.layout(patch);

        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        for (const box of this.boxes.values()) {
            minX = Math.min(minX, box.x);
            minY = Math.min(minY, box.y);
            maxX = Math.max(maxX, box.x + BOX_WIDTH);
            maxY = Math.max(maxY, box.y + BOX_HEIGHT);
        }

        const width = maxX - minX + PADDING * 2;
        const height = maxY - minY + PADDING * 2;

        // The width and height attributes are what give the element an intrinsic ratio, and
        // without them `height: auto` does not mean "keep the shape" — an SVG with only a
        // viewBox has no intrinsic size, so `auto` resolves against the container and the
        // drawing is squashed to whatever height the box happens to be. That is how the 808
        // kit, which is eight screens tall, rendered as a 330-pixel stamp with 3-pixel
        // lettering. With them, a tall patch makes a tall element and the box scrolls.
        const svg = element('svg', {
            class: 'graph-svg',
            viewBox: `${minX - PADDING} ${minY - PADDING} ${width} ${height}`,
            width,
            height,
            role: 'img',
        });

        // The signal order in words, for anyone reading this with a screen reader. An SVG
        // full of <rect> is a picture of nothing without it.
        const title = element('title');
        title.textContent = patch.metadata?.name
            ? `Signal graph: ${patch.metadata.name}`
            : 'Signal graph';
        const description = element('desc');
        description.textContent = this.describe(patch);
        svg.append(title, description);

        const cables = element('g', { class: 'cables' });
        const nodes = element('g', { class: 'graph-nodes' });
        svg.append(cables, nodes);

        for (const connection of patch.connections ?? []) {
            const cable = this.drawCable(connection);
            if (cable) cables.append(cable);
        }
        // The golden moment, ported from the desktop's cable pass
        // (docs/graph-cable-system.md): rest a pointer on a cable and every route that is
        // not its family goes quiet, while the chosen one stays exactly as it was. A click
        // makes it persistent; Esc, clicking it again, or clicking empty canvas lets go.
        //
        // Each visible cable gets an invisible wide twin to take the pointer — a few px of
        // ink is not a target. The twins live INSIDE the cables group, below the nodes, so
        // a cable passing under a node cannot be grabbed through it: the node wins there,
        // which is the desktop's hit-testing rule arriving free with SVG paint order.
        for (const cable of [...cables.querySelectorAll('.cable')]) {
            const hit = element('path', { d: cable.getAttribute('d'), class: 'cable-hit' });
            const family = cable.dataset.family;
            hit.addEventListener('pointerenter', () => this.setRoute(family));
            hit.addEventListener('pointerleave', () => this.setRoute(null));
            hit.addEventListener('click', (event) => {
                event.stopPropagation();
                this.lockRoute(this.lockedRoute === family ? null : family);
            });
            cables.append(hit);
        }
        svg.addEventListener('click', () => this.lockRoute(null));
        for (const id of this.boxes.keys()) {
            nodes.append(this.drawNode(id));
        }

        this.host.append(svg);
        this.svg = svg;
        this.applyAttention();
    }

    // The same left-to-right story the picture tells, in a sentence.
    //
    // Topological, not breadth-first. Breadth-first was the obvious thing and it was wrong:
    // in the tutorial patch it announced the amplifier before the filter, because the
    // amplifier is two cables from the clock along the envelope while the filter is three
    // along the audio. A description of signal order that names a node before the thing
    // feeding it is worse than no description — this is the only account of the graph
    // somebody using a screen reader gets.
    describe(patch) {
        const nodes = patch.nodes ?? [];
        const connections = patch.connections ?? [];

        const remaining = new Map(nodes.map((node) => [node.id, 0]));
        for (const connection of connections) {
            if (remaining.has(connection.to.node) && remaining.has(connection.from.node)) {
                remaining.set(connection.to.node, remaining.get(connection.to.node) + 1);
            }
        }

        // Seeded in the patch's own order, so two nodes that are equally ready are named in
        // the order the file lists them rather than in whatever order a Map happened to be.
        const ready = nodes.filter((node) => remaining.get(node.id) === 0).map((node) => node.id);
        const order = [];
        const seen = new Set();

        while (ready.length > 0) {
            const id = ready.shift();
            if (seen.has(id)) continue;
            seen.add(id);
            order.push(this.label(this.boxes.get(id)?.node ?? { id }));
            for (const connection of connections) {
                if (connection.from.node !== id || !remaining.has(connection.to.node)) continue;
                const left = remaining.get(connection.to.node) - 1;
                remaining.set(connection.to.node, left);
                if (left === 0) ready.push(connection.to.node);
            }
        }
        // Anything inside a feedback cycle never reaches zero. Naming it last is better than
        // leaving it out of the description entirely.
        for (const node of nodes) {
            if (!seen.has(node.id)) order.push(this.label(node));
        }
        return `Signal flows: ${order.join(', then ')}.`;
    }

    drawCable(connection) {
        const from = this.anchor(connection.from.node, connection.from.port, 'out');
        const to = this.anchor(connection.to.node, connection.to.port, 'in');
        if (!from || !to) return null;

        // Enough horizontal pull that every cable leaves and arrives level, which is what
        // makes a bundle of them readable. A backwards cable — feedback — gets the same
        // treatment rather than a special case, so it draws as a visible loop.
        const reach = Math.max(70, Math.abs(to.x - from.x) * 0.45);

        const path = element('path', {
            d: `M ${from.x} ${from.y} C ${from.x + reach} ${from.y}, ` +
                `${to.x - reach} ${to.y}, ${to.x} ${to.y}`,
            class: `cable ${this.signalType(connection)}`,
        });
        path.dataset.from = connection.from.node;
        path.dataset.to = connection.to.node;
        // Two cables leaving one output port are one signal fanning out, so they focus and
        // quiet together — the desktop's port-family rule. The key is the output port.
        path.dataset.family = `${connection.from.node}:${connection.from.port}`;
        return path;
    }

    drawNode(id) {
        const box = this.boxes.get(id);
        const descriptor = this.descriptor(box.node.type);

        // Focusable and labelled. The picture is also a way to move around the patch, and
        // a <g> is invisible to anything that is not a mouse unless it is told not to be —
        // the same reason the on-screen keyboard is made of buttons rather than divs.
        const group = element('g', {
            class: 'graph-node',
            transform: `translate(${box.x} ${box.y})`,
            tabindex: '0',
            role: 'button',
            'aria-label': `${this.label(box.node)}, ${box.node.type}` +
                `${descriptor ? `. ${descriptor.summary}` : ''}`,
        });
        group.dataset.node = id;

        group.append(element('rect', {
            width: BOX_WIDTH,
            height: BOX_HEIGHT,
            rx: 16,
            class: 'node-body',
        }));

        const name = element('text', { x: 26, y: 62, class: 'node-name' });
        name.textContent = this.label(box.node);

        const type = element('text', { x: 26, y: 104, class: 'node-type' });
        // A module instance has no registry entry — it is notation, expanded at load — so
        // the useful thing to show is which definition it instantiates.
        type.textContent = box.node.module
            ? `module · ${box.node.module}`
            : (descriptor?.category ? `${box.node.type} · ${descriptor.category}` : box.node.type);

        const identity = element('text', { x: 26, y: 150, class: 'node-id' });
        identity.textContent = id;

        group.append(name, type, identity);

        const select = () => this.dispatchEvent(new CustomEvent('nodeselect', { detail: id }));
        group.addEventListener('click', select);
        group.addEventListener('keydown', (event) => {
            if (event.key === 'Enter' || event.key === ' ') {
                event.preventDefault();
                select();
            }
        });
        return group;
    }

    // -------------------------------------------------------------------------------
    // Attention
    //
    // Two separate ideas, kept separate on purpose. `focus` is the tour saying "look at
    // these"; `active` is the page saying "the control you are holding drives this one".
    // Both are true at once during the golden moment, and they mean different things.
    // -------------------------------------------------------------------------------

    setFocus(nodeIds) {
        this.focused = nodeIds === null || nodeIds === undefined ? null : new Set(nodeIds);
        this.applyAttention();
    }

    setActive(nodeId) {
        this.active = nodeId ?? null;
        this.applyAttention();
    }

    // Transient focus — the pointer resting on a route. Never fights a lock: while a route
    // is locked, hovering elsewhere changes nothing, which is what "persistent" means.
    setRoute(family) {
        this.route = family ?? null;
        this.applyAttention();
    }

    // Persistent focus. Locking and unlocking render identically to the transient kind —
    // the desktop's rule that lock state gets no colour, border, glow or width of its own.
    lockRoute(family) {
        if (this.lockedRoute === (family ?? null)) return;
        this.lockedRoute = family ?? null;
        this.applyAttention();
        if (this.lockedRoute !== null) this.onRouteLocked?.();
    }

    applyAttention() {
        if (!this.svg) return;
        const lit = (id) => this.focused === null || this.focused.has(id);

        for (const group of this.svg.querySelectorAll('.graph-node')) {
            const id = group.dataset.node;
            group.classList.toggle('dim', !lit(id));
            group.classList.toggle('active', id === this.active);
        }
        // Lock beats hover; nothing focused is the ordinary case and costs nothing.
        // The chosen family is not restyled — everything else is quieted. Nodes are never
        // suppressed, exactly as on the desktop.
        const chosen = this.lockedRoute ?? this.route;
        for (const cable of this.svg.querySelectorAll('.cable')) {
            cable.classList.toggle('dim', !(lit(cable.dataset.from) && lit(cable.dataset.to)));
            cable.classList.toggle('quiet',
                chosen !== null && cable.dataset.family !== chosen);
            cable.classList.toggle('active',
                this.active !== null && cable.dataset.from === this.active);
        }
    }
}
