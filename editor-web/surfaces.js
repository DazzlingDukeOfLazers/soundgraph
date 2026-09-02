// The three ways to run SoundGraph, and what it costs to reach each one.
//
// This page is one of them, so it is the natural place to say the other two exist — the
// complaint that started this was that the doorway gave no sign there was a building
// behind it.
//
// URLS ARE CONFIGURATION AND DEFAULT TO NOTHING. A surface with no `url` is announced but
// not linked: it says what it is and that it is not ready, rather than offering a link
// that 404s. Nothing here invents a deployment that has not been decided — the same rule
// the mailing-list endpoint follows.
//
// WHERE THE FULL EDITOR MAY LIVE IS NOT A FREE CHOICE. The Godot export ships a service
// worker, and a service worker's scope is the directory it is served from. Its caching is
// cache-first with no revalidation and updates land a visit late (see
// editor-godot/README.md). Hosted at or above this page it would take control of this page
// too, and the marketing page would become one that cannot be reliably updated. It must
// live in a directory BELOW this one:
//
//   /soundgraph              this page
//   /soundgraph/editor-web   the full editor, with its own worker scope
//   /soundgraph/desktop      the desktop download
//
// Relative URLs, so the same build works on localhost, on a staging host and in
// production without a rebuild. Locally the export sits at ./editor/; in production
// (tools/cloudflare/worker.js) that same relative link 301s to /soundgraph/editor-web/,
// the editor's canonical home in R2. Same origin either way — the handoff is
// localStorage, and localStorage does not cross origins.

export const SURFACES = [
    {
        id: 'browser',
        name: 'In your browser',
        here: true,
        summary: 'Hear a patch and change it. Nothing to install, and about 650 KB to load.',
        detail: 'Reads a graph, plays it, and lets you move any control the patch exposes.',
        url: null,
    },
    {
        id: 'full',
        name: 'The full editor',
        summary: 'Build patches visually — add nodes, drag cables, search by what you want.',
        detail: 'The same editor as the desktop application, running in this browser.',
        // Below this page, so the export's service worker scope cannot reach it.
        // `node tools/export-web.mjs --out editor-web/editor` puts it here.
        url: './editor/',
        // Roughly 10 MB gzipped on the first visit, then cached by its service worker.
        // Said out loud rather than sprung on somebody halfway through a download.
        cost: 'About 10 MB the first time. After that it works offline.',
        // Warmed once a visitor has shown they are interested — never before, and never on
        // a metered connection. These are the names Godot's exporter actually emits, read
        // off the export rather than guessed: `index` is `executable` in export_presets,
        // so renaming that renames all of these. Biggest first, since that is the one whose
        // download decides whether the click feels instant.
        preload: [
            'index.side.wasm',                              // ~44 MB, the engine
            'index.pck',                                    // ~4 MB, the editor itself
            'index.wasm',                                   // ~1.5 MB, the loader
            'soundgraph_godot.web.wasm32.nothreads.wasm',   // ~1.3 MB, dsp-core
        ],
    },
    {
        id: 'desktop',
        name: 'Desktop',
        summary: 'The full editor as an application, for when the browser is not the point.',
        detail: 'Opens and saves patch files directly, and talks to hardware over serial.',
        url: null,
        cost: 'No numbered release yet.',
    },
];

export function surface(id) {
    return SURFACES.find((entry) => entry.id === id) ?? null;
}

/** Has this surface somewhere to point? Everything user-facing keys off this. */
export function isReachable(id) {
    const found = surface(id);
    return typeof found?.url === 'string' && found.url.length > 0;
}
