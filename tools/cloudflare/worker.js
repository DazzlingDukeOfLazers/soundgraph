// The public face of SoundGraph on mutantfactory.com — one Worker, one origin, three jobs:
//
//   /soundgraph/             the marketing page, bundled with the Worker as static assets
//   /soundgraph/editor-web/  the full editor — 53 MB of Godot export served from R2,
//                            because index.side.wasm (44 MB) is past the 25 MiB
//                            static-asset limit
//   /soundgraph/editor/      where the page's relative links land; a 301 carries them to
//                            /soundgraph/editor-web/, so the same build works on
//                            localhost (where the export sits at editor-web/editor/)
//                            without a rewrite
//   /examples/patches/       the example patches, from R2 under 'patches/'. The page
//                            fetches them at '../examples/patches/' — one directory UP
//                            from itself, mirroring the repository, which is what a dev
//                            server serving the repo root provides for free — so in
//                            production they land outside /soundgraph and this Worker
//                            claims that path too. Without it the page loads and then
//                            has nothing to play.
//
// ONE ORIGIN IS NOT A NICETY. The patch handoff is localStorage
// ('soundgraph.handoff.v1'): serve the editor from a bucket subdomain and the
// "Open the full editor" click forgets the patch. The editor also lives BELOW the page
// so its cache-first service worker scope cannot capture the page (surfaces.js).

const BASE = '/soundgraph';
const EDITOR = '/editor-web';
const PATCHES = '/examples/patches/';

// One R2 object, HTTP-shaped: honest etag, a revalidating hour of freshness, and a 304
// when the visitor's cache is already right — which for the 44 MB engine is the
// difference between a click and a coffee.
async function fromBucket(bucket, key, request) {
    const object = await bucket.get(key, { onlyIf: request.headers });
    if (object === null) {
        return new Response('Not found', { status: 404 });
    }
    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    // The export's filenames are not content-hashed, so no immutable here — an hour of
    // freshness, then a cheap etag check.
    headers.set('cache-control', 'public, max-age=3600');
    if (object.body === undefined) {
        return new Response(null, { status: 304, headers });
    }
    return new Response(object.body, { headers });
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        if (url.pathname.startsWith(PATCHES)) {
            return fromBucket(env.EDITOR_BUCKET,
                `patches/${url.pathname.slice(PATCHES.length)}`, request);
        }

        // Without the trailing slash, the page's relative asset URLs would resolve to
        // the domain root, outside this Worker's route.
        if (url.pathname === BASE) {
            return Response.redirect(`${url.origin}${BASE}/`, 301);
        }
        if (!url.pathname.startsWith(`${BASE}/`)) {
            return new Response('Not found', { status: 404 });
        }
        const path = url.pathname.slice(BASE.length);

        // The page says './editor/' everywhere; production's name for that is a hop away.
        if (path === '/editor' || path.startsWith('/editor/')) {
            const rest = path.slice('/editor'.length) || '/';
            return Response.redirect(`${url.origin}${BASE}${EDITOR}${rest}`, 301);
        }

        if (path === EDITOR) {
            return Response.redirect(`${url.origin}${BASE}${EDITOR}/`, 301);
        }
        if (path.startsWith(`${EDITOR}/`)) {
            return fromBucket(env.EDITOR_BUCKET,
                path.slice(EDITOR.length + 1) || 'index.html', request);
        }

        // Everything else is the marketing page; its files are bundled at the asset root,
        // so strip the base before asking.
        return env.ASSETS.fetch(new Request(new URL(path, url.origin), request));
    },
};
