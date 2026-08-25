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
//   /soundgraph            this page
//   /soundgraph/editor     the full editor, with its own worker scope
//   /soundgraph/desktop    the desktop download
//
// Relative URLs, so the same build works on localhost, on a staging host and in
// production without a rebuild.

export const SURFACES = [
    {
        id: 'browser',
        name: 'In your browser',
        here: true,
        summary: 'Hear a patch and change it. Nothing to install, and about 400 KB to load.',
        detail: 'Reads a graph, plays it, and lets you move any control the patch exposes.',
        url: null,
    },
    {
        id: 'full',
        name: 'The full editor',
        summary: 'Build patches visually — add nodes, drag cables, search by what you want.',
        detail: 'The same editor as the desktop application, running in this browser.',
        // e.g. './editor/' once it is deployed. Must be BELOW this page — see above.
        url: null,
        // Roughly 10 MB gzipped on the first visit, then cached by its service worker.
        // Said out loud rather than sprung on somebody halfway through a download.
        cost: 'About 10 MB the first time. After that it works offline.',
        // Files to warm once a visitor has shown they are interested. Left empty on
        // purpose: the names come from the Godot export and guessing them would produce a
        // prefetch that quietly fetches nothing, which is worse than no prefetch at all.
        // Fill from the export directory — index.wasm, index.pck and index.side.wasm.
        preload: [],
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
