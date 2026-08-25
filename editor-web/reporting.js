// The only thing on this page that talks to a server.
//
// Two errands, both against the Mutant Factory feedback service — the envelope contract
// is `schema/envelope.v1.md` in that repository, and this file is a second application
// conforming to it without sharing a line of code with the first, which is the point of
// having written the contract down.
//
//   the funnel   one report per visit, updated in place, saying how far the introduction
//                got. No patch contents, no audio, no email address, no device data
//                beyond a browser family.
//   the signup   one report when somebody asks to join the mailing list, carrying the
//                address they typed and nothing else.
//
// WHAT THIS COSTS, SAID PLAINLY. The feedback store is built for reports a person wrote,
// read daily by a human through `tools/triage.py`. Funnel rows are neither written by a
// person nor worth reading one at a time, and they will outnumber real reports quickly.
// They are kept out of the way by `element_key` (`onboarding/...`) and by `app`, so
// `triage.py --app "Raves of Qud"` is unaffected and `triage.py groups` buckets them into
// two rows rather than hundreds. If that stops being a good enough answer, FUNNEL_REPORTS
// below is the switch, and turning it off costs the funnel and nothing else.
//
// A funnel row from a dev origin is marked `test`, which the server accepts and discards.
// Otherwise every reload while working on this page would write one, and the people
// polluting the store worst would be the two who read it.
//
// Nothing here is allowed to take the instrument down. Every network call is guarded, a
// refusal is remembered rather than retried in a loop, and the page works identically
// with the endpoint unreachable — which is also what happens when someone blocks it.

import { visitorId } from './local-store.js';

// ---------------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------------

/** The deployed service. Its CORS allow-list must name whatever origin serves this page —
 *  `localhost` and `private` are already on it, so a dev server works untouched. */
export const ENDPOINT = 'https://feedback.mutantfactory.net';

/** One product, two kinds of row, told apart by element_key. */
export const APP = 'SoundGraph';

/** The kill switch described above. Signups are separate and stay on. */
export const FUNNEL_REPORTS = true;

/** Every milestone the measurement plan asks for, and no others. Exported as the only
 *  spelling of these names, so a typo is a missing import rather than a row that quietly
 *  never matches anything. */
export const MILESTONES = Object.freeze({
    ONBOARDING_STARTED: 'onboarding_started',
    AUDIO_STARTED: 'audio_started',
    TUTORIAL_PATCH_HEARD: 'tutorial_patch_heard',
    FIRST_PARAMETER_CHANGED: 'first_parameter_changed',
    GOLDEN_MOMENT_COMPLETED: 'onboarding_golden_moment_completed',
    PATCH_SAVED: 'patch_saved',
    SECOND_PATCH_LOADED: 'second_patch_loaded',
    EMAIL_PROMPT_SHOWN: 'email_prompt_shown',
    EMAIL_SIGNUP_SUBMITTED: 'email_signup_submitted',
    ONBOARDING_SKIPPED: 'onboarding_skipped',
});

// ---------------------------------------------------------------------------------
// What we know about ourselves
// ---------------------------------------------------------------------------------

/**
 * Browser family, and deliberately nothing else. Not the version, not the operating
 * system, not the screen.
 *
 * It is here for one question the funnel exists to answer — "are people blocked by audio
 * activation?" — which is browser-specific in a way nothing else on this page is. Anything
 * finer would be device data collected because it was available rather than because a
 * question needed it.
 */
export function browserFamily(userAgent = navigator.userAgent) {
    const agent = String(userAgent);
    if (/Firefox\//.test(agent)) return 'web/Firefox';
    if (/Edg\//.test(agent)) return 'web/Edge';
    if (/OPR\/|Opera/.test(agent)) return 'web/Opera';
    if (/Chrome\//.test(agent)) return 'web/Chrome';
    // Safari last: every browser above also says "Safari" in its user agent string.
    if (/Safari\//.test(agent)) return 'web/Safari';
    return 'web';
}

// An IPv4 octet, so `10.999.1.1` is not quietly treated as an address. Same shape as the
// service's own cors.js, on purpose: these two lists have to mean the same thing by "a dev
// origin", and the day they disagree is the day local rows start landing in the store.
const OCTET = '(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)';

const LOOPBACK = new RegExp(`^https?://(localhost|127\\.${OCTET}\\.${OCTET}\\.${OCTET})(:\\d{1,5})?$`);

const PRIVATE_LAN = new RegExp(
    '^https?://(' +
        `10\\.${OCTET}\\.${OCTET}\\.${OCTET}` +
        `|192\\.168\\.${OCTET}\\.${OCTET}` +
        `|172\\.(1[6-9]|2\\d|3[01])\\.${OCTET}\\.${OCTET}` +
        '|[a-z0-9][a-z0-9-]*\\.local' +
    ')(:\\d{1,5})?$'
);

/**
 * Is this page being served from somebody's own machine?
 *
 * Anchored at both ends, which is the whole job: `localhost.example.com` is a domain
 * anybody can register, and a check that merely looked for "localhost" would hand every
 * page on it a way to have its rows thrown away.
 */
export function isDevelopmentOrigin(origin = globalThis.location?.origin ?? '') {
    const value = String(origin).trim().toLowerCase().replace(/\/+$/, '');
    return LOOPBACK.test(value) || PRIVATE_LAN.test(value);
}

/**
 * Which build this is. `tools/stamp-build.mjs --target web-editor` writes the file; it is
 * not committed, so running from source has none and says "development" rather than
 * claiming to be a release. A report you cannot pin to a build is close to worthless, and
 * one that names the wrong build is worse than one that admits it does not know.
 */
let buildVersion = 'development';

export async function loadBuildStamp(url = './build_stamp.json') {
    try {
        const response = await fetch(url, { cache: 'no-store' });
        if (!response.ok) return buildVersion;
        const stamp = await response.json();
        if (typeof stamp.short === 'string' && stamp.short.length > 0) {
            buildVersion = stamp.short;
        }
    } catch {
        /* no stamp on disk: "development" is the truth */
    }
    return buildVersion;
}

export function version() {
    return buildVersion;
}

// ---------------------------------------------------------------------------------
// The funnel
//
// Milestones accumulate in memory and are posted as ONE report, keyed on a report_id that
// is stable for the visit. Flushing twice updates the row rather than adding one, which is
// exactly the idempotency the envelope was designed around — so this can flush eagerly at
// the moments that matter and again when the page goes away, without counting anything
// twice.
// ---------------------------------------------------------------------------------

const startedAt = Date.now();
const reached = [];
let lastSent = '';

/** Record a milestone. The first time only — a funnel step is a thing that happened, not
 *  a counter, and re-entering a step is not new information. */
export function milestone(name) {
    if (reached.some((entry) => entry.name === name)) {
        return false;
    }
    reached.push({ name, at_ms: Date.now() - startedAt });
    return true;
}

/** The one-line summary a human sees in triage. Machine-written, and it should read like
 *  it: the story of one visit, in order, with the clock. */
export function funnelText(entries = reached) {
    if (entries.length === 0) {
        return 'onboarding funnel: nothing happened.';
    }
    const steps = entries.map((entry) => `${entry.name}@${Math.round(entry.at_ms / 100) / 10}s`);
    return `onboarding funnel: ${steps.join(' -> ')}`;
}

function envelope(fields) {
    return {
        v: 1,
        app: APP,
        app_version: buildVersion,
        platform: browserFamily(),
        install_id: visitorId(),
        ts: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
        source: 'editor-web',
        ...fields,
    };
}

async function post(body, { keepalive = false } = {}) {
    const response = await fetch(`${ENDPOINT}/v1/report`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
        keepalive,
    });
    return response;
}

/**
 * Send the funnel so far.
 *
 * `keepalive` because the most useful call is the one on the way out of the page, where a
 * normal fetch is cancelled with the document. Never awaited by anything the visitor is
 * waiting on, and never allowed to throw at a caller: a funnel that failed to send is a
 * measurement problem, and a measurement problem must not become an instrument problem.
 */
export async function flushFunnel({ keepalive = false } = {}) {
    if (!FUNNEL_REPORTS || reached.length === 0) {
        return false;
    }
    const text = funnelText();
    // Nothing changed since the last flush: the row would be identical, so do not write it.
    if (text === lastSent) {
        return false;
    }
    try {
        await post(envelope({
            report_id: `${visitorId()}|onboarding|${startedAt}`,
            element_key: 'onboarding/funnel',
            text,
            milestones: reached,
            // A funnel row from a dev machine is somebody testing the page, and every
            // reload of it would otherwise become a row in the store a human reads. The
            // server refuses `test` at the door — 202, nothing written — so the whole path
            // still gets exercised locally and none of it accumulates.
            //
            // This applies to the funnel ONLY. A signup from a dev origin is still a person
            // asking to join, and throwing their address away to keep a store tidy is the
            // wrong trade.
            ...(isDevelopmentOrigin() ? { test: true } : {}),
        }), { keepalive });
        lastSent = text;
        return true;
    } catch {
        return false;
    }
}

// ---------------------------------------------------------------------------------
// The mailing list
// ---------------------------------------------------------------------------------

/** Deliberately loose. The server does not verify addresses and neither should this — the
 *  only job here is to catch the obvious slip before it costs somebody their signup, not
 *  to adjudicate what a legal address looks like. */
export function looksLikeAddress(value) {
    const trimmed = String(value ?? '').trim();
    return trimmed.length >= 3 && trimmed.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed);
}

/**
 * Join the list. Resolves {ok: true} or {ok: false, message} — never throws, because the
 * caller's job is to show the visitor a sentence, and every failure here has a sentence.
 *
 * The address travels in its own field rather than inside `text`. Both are read by the
 * same human, but a field can be exported to a mailing tool later and a sentence cannot.
 */
export async function joinMailingList(address) {
    const email = String(address ?? '').trim();
    if (!looksLikeAddress(email)) {
        // `kind` exists so the panel can pick a heading that matches. Telling somebody
        // "that did not connect" when nothing was ever sent sends them to check their
        // wifi over a typo.
        return {
            ok: false,
            kind: 'address',
            message: 'That address does not look complete. Check it and try again.',
        };
    }

    try {
        const response = await post(envelope({
            report_id: `${visitorId()}|mailing|${Date.now()}`,
            element_key: 'onboarding/mailing_list',
            text: 'Mailing list signup from the SoundGraph web editor. This visitor asked to ' +
                'receive the Mutant Factory dispatch.',
            email,
            consent: 'submitted the mailing-list form in the SoundGraph onboarding panel',
        }));

        if (response.status === 202 || response.status === 200) {
            return { ok: true };
        }
        if (response.status === 429) {
            return { ok: false, kind: 'connection', message: 'Too many requests from here just now. Try again in a minute.' };
        }
        if (response.status === 503) {
            return { ok: false, kind: 'connection', message: 'Signups are paused at the moment. Try again later.' };
        }
        return { ok: false, kind: 'address', message: 'The list did not accept that. Check the address, or try again later.' };
    } catch {
        // A blocked request and an offline machine look identical from here, and both are
        // honestly described as "did not connect".
        return { ok: false, kind: 'connection', message: 'That did not connect. Check your connection and try again.' };
    }
}
