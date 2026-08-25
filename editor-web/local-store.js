// Everything this page remembers between visits, in one file.
//
// There is exactly one reason to keep it together: it is the whole of what the page knows
// about a person, and a privacy claim you cannot check in one place is a privacy claim
// nobody can check. Four keys, listed below, and nothing else is written anywhere.
//
//   soundgraph.visitor.v1     a random id, so a repeated report updates in place
//   soundgraph.onboarding.v1  how far the introduction got, and whether it is finished
//   soundgraph.patch.v1       the patch the visitor last saved, so a return opens into it
//   soundgraph.mailing.v1     whether the mailing-list panel has been answered
//   soundgraph.handoff.v1     a patch on its way to the full editor, read once and cleared
//
// localStorage can throw — Safari in private browsing, a storage quota, a browser
// configured to refuse it — and every one of those is a reason to lose a preference, not
// a reason to take the instrument down. So every access is guarded and every read has an
// answer for "there is no storage here at all".

const KEYS = {
    visitor: 'soundgraph.visitor.v1',
    onboarding: 'soundgraph.onboarding.v1',
    patch: 'soundgraph.patch.v1',
    mailing: 'soundgraph.mailing.v1',
    handoff: 'soundgraph.handoff.v1',
};

function read(key, fallback = null) {
    try {
        const raw = window.localStorage.getItem(key);
        return raw === null ? fallback : JSON.parse(raw);
    } catch {
        return fallback;
    }
}

function write(key, value) {
    try {
        window.localStorage.setItem(key, JSON.stringify(value));
        return true;
    } catch {
        return false;
    }
}

function remove(key) {
    try {
        window.localStorage.removeItem(key);
    } catch {
        /* nothing to forget, or nowhere to forget it */
    }
}

/**
 * A random id for this browser, made here and never derived from anything about the
 * machine. It exists so a report retried after a reload updates its row instead of
 * becoming a second one, and so "did anyone come back" is answerable — see the About
 * panel, which says this out loud rather than leaving it to be discovered.
 *
 * Clearing site data clears it, and a fresh id is simply a new visitor.
 */
export function visitorId() {
    const existing = read(KEYS.visitor);
    if (typeof existing === 'string' && existing.length > 0) {
        return existing;
    }
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    const id = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
    write(KEYS.visitor, id);
    return id;
}

// ---------------------------------------------------------------------------------
// Onboarding progress
// ---------------------------------------------------------------------------------

const EMPTY_PROGRESS = { started: false, completed: false, skipped: false, step: null };

export function onboardingProgress() {
    const stored = read(KEYS.onboarding);
    return stored && typeof stored === 'object' ? { ...EMPTY_PROGRESS, ...stored } : { ...EMPTY_PROGRESS };
}

export function rememberProgress(changes) {
    const next = { ...onboardingProgress(), ...changes };
    write(KEYS.onboarding, next);
    return next;
}

/** Restart introduction, from Help. Forgets the progress and nothing else. */
export function forgetOnboarding() {
    remove(KEYS.onboarding);
}

// ---------------------------------------------------------------------------------
// The saved patch
//
// Local only. There is no account, no upload and no server copy — "Save locally" means
// what it says, and the Save .json button next to it is how a patch leaves this machine.
// ---------------------------------------------------------------------------------

export function savePatchLocally(text, name) {
    return write(KEYS.patch, { text, name: name ?? 'Untitled', saved: new Date().toISOString() });
}

export function savedPatch() {
    const stored = read(KEYS.patch);
    return stored && typeof stored.text === 'string' ? stored : null;
}

export function forgetSavedPatch() {
    remove(KEYS.patch);
}

/**
 * The patch being carried to another surface.
 *
 * Deliberately NOT the same key as the saved patch. "Open this in the full editor" is a
 * different act from "save this", and writing the handoff over somebody's saved work
 * because both are a patch in localStorage would be a data-loss bug wearing a convenience
 * feature's clothes. The full editor reads this, uses it once, and clears it.
 */
export function handOffPatch(text, name) {
    return write(KEYS.handoff, { text, name: name ?? 'Untitled', at: new Date().toISOString() });
}

export function handedOffPatch() {
    const stored = read(KEYS.handoff);
    return stored && typeof stored.text === 'string' ? stored : null;
}

export function clearHandOff() {
    remove(KEYS.handoff);
}

// ---------------------------------------------------------------------------------
// The mailing-list panel
//
// Remembered so the invitation is offered once. Declining is an answer, and asking again
// on the next visit would make it a nag rather than an offer.
// ---------------------------------------------------------------------------------

export function mailingState() {
    const stored = read(KEYS.mailing);
    return stored && typeof stored === 'object' ? stored : { answered: false, joined: false };
}

export function rememberMailing(changes) {
    const next = { ...mailingState(), ...changes };
    write(KEYS.mailing, next);
    return next;
}

/** Everything above, forgotten. Wired to a button in the About panel. */
export function forgetEverything() {
    for (const key of Object.values(KEYS)) {
        remove(key);
    }
}

export const STORAGE_KEYS = KEYS;
