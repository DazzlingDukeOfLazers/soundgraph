// The first two minutes.
//
// The whole shape of this file is one rule: the visitor hears something, changes it, and
// understands why it changed — and only then is anything asked of them. Nothing here
// blocks the instrument, nothing here is a prerequisite for using the page, and the
// mailing-list panel cannot appear until the golden moment has already happened.
//
// The script it implements, step by step:
//
//   arrival    the promise, and the click browsers require before audio exists
//   hear       the whole patch, playing, before any machinery is explained
//   read       four sentences, left to right, each lighting its own part of the graph
//   invite     one control, named, with no Next button — the change IS the next step
//   golden     what just happened, and a toggle between Original and Your version
//   agency     where to go now, and the only place the mailing list can be offered
//
// Two things are worth knowing before editing it.
//
// EVERY STEP AFTER THE FIRST IS NON-BLOCKING. Only the arrival screen is a modal, because
// only the arrival screen needs a gesture. The rest are coach marks: cards beside a ring
// drawn around whatever they are talking about. A visitor can drag a knob, play the
// keyboard or edit the JSON at any point during the tour, which is the difference between
// playing an instrument and completing software training.
//
// SILENCE IS A REAL PATH, NOT AN ERROR PATH. Audio can fail, and a visitor can choose to
// continue without it. When that happens the tour keeps working and keeps its mouth shut
// about hearing things — and the golden-moment milestone is NOT recorded, because it did
// not happen. A funnel that counts silent visitors as having heard the difference is a
// funnel that will cheerfully report success at the one thing this page exists to do.

import {
    MILESTONES,
    flushFunnel,
    joinMailingList,
    milestone,
} from './reporting.js';
import {
    mailingState,
    onboardingProgress,
    rememberMailing,
    rememberProgress,
} from './local-store.js';

// ---------------------------------------------------------------------------------
// Copy
//
// All of it, in one object. Wording is the part of this feature most likely to be
// rewritten and least likely to be rewritten by whoever wrote the state machine.
// ---------------------------------------------------------------------------------

export const COPY = {
    arrival: {
        title: 'SoundGraph',
        promise: 'See the sound. Change the sound.',
        body: 'SoundGraph turns a synthesizer patch into something you can follow. ' +
            'We will start with one small signal chain and change it together.',
        start: 'Start with sound',
        skip: 'Explore without the tour',
        volume: 'Audio will begin after you press Start. Check your volume first.',
    },
    // Two failures, two messages. The browser refusing to start audio is the visitor's end
    // and worth checking a volume knob over; the sound module failing to arrive is ours, and
    // no amount of checking their output device will help. Both used to say the second
    // thing, which meant the only failure this page could actually produce from a fresh
    // clone was also the one it described wrongly.
    audioFailure: {
        title: 'We do not have audio yet.',
        body: 'Your browser may be waiting for permission or using a different output ' +
            'device. Check your volume and audio output, then try again.',
        retry: 'Try audio again',
        silent: 'Continue silently',
    },
    engineFailure: {
        title: 'The sound engine did not load.',
        body: 'SoundGraph makes its sound in a module this page downloads, and that download ' +
            'did not arrive. That is this end, not yours — nothing is wrong with your volume ' +
            'or your speakers. A reload often fixes it, and everything else on this page ' +
            'works without it.',
        retry: 'Try again',
        silent: 'Continue without sound',
    },
    hear: {
        title: 'This is the complete patch.',
        body: 'The pulse is already moving through these four connected parts. ' +
            'Listen once before changing anything.',
        bodySilent: 'These four connected parts are the whole patch. There is no sound ' +
            'yet — the rest of the tour still works, and you can start audio at any time.',
        next: 'I hear it',
        nextSilent: 'Go on',
        stop: 'Stop sound',
        resume: 'Play again',
    },
    read: {
        title: 'Read it from left to right.',
        lines: [
            { text: 'The sequence chooses when a note happens.', nodes: ['clock', 'seq', 'env'] },
            { text: 'The oscillator creates the tone.', nodes: ['osc'] },
            { text: 'The filter shapes it.', nodes: ['filter'] },
            { text: 'The output lets you hear it.', nodes: ['amp', 'out'] },
        ],
        next: 'Show me the filter',
    },
    invite: {
        title: 'Make it brighter.',
        body: 'Drag this control to the right while the patch is playing. The filter ' +
            'removes or restores high frequencies. You should hear the sound open as the ' +
            'value rises.',
        bodySilent: 'Drag this control to the right. The filter removes or restores high ' +
            'frequencies — with audio running you would hear the sound open as the value ' +
            'rises.',
        prompt: 'Try it now.',
    },
    golden: {
        title: 'You changed the graph — and heard why.',
        titleSilent: 'You changed the graph.',
        body: 'The oscillator still creates the same tone. You changed what the filter ' +
            'allows through.',
        compare: 'Compare with the original',
        keep: 'Keep my version',
        original: 'Original',
        yours: 'Your version',
    },
    agency: {
        title: 'Your patch is alive.',
        intro: 'From here, you can:',
        items: [
            'Change the oscillator to reshape the source.',
            'Move the filter again.',
            'Load another factory patch.',
            'Save this version locally.',
        ],
        keepGoing: 'Keep experimenting',
        save: 'Save this patch',
        more: 'Show me one more thing',
    },
    structural: {
        title: 'One more thing: take the filter out of the path.',
        body: 'Everything so far was a value. This is a cable. Bypassing the filter sends ' +
            'the oscillator straight to the amplifier — the filter stays in the patch with ' +
            'nothing running through it, which is exactly what the picture will show.',
        bypass: 'Bypass the filter',
        restore: 'Put the filter back',
        done: 'Done',
        bypassed: 'The oscillator now reaches the output without passing through the ' +
            'filter. Nothing else changed.',
        restored: 'The filter is back in the path.',
    },
    mailing: {
        title: 'Want the next mutation?',
        body: 'SoundGraph is still becoming a complete instrument. Join the occasional ' +
            'Mutant Factory dispatch for new builds, patches, and invitations to test what ' +
            'comes next.',
        label: 'Email address',
        submit: 'Keep me in the loop',
        decline: 'Not now — keep patching',
        // Deliberately not "no tracking": that is a claim, and an unverified claim about
        // privacy is worse than no claim. What is stated here is what the code does.
        smallPrint: 'Your address goes to the Mutant Factory dispatch and nowhere else. ' +
            'It is read by a person, not fed to an advertiser. Unsubscribe whenever you like.',
        working: 'Sending…',
        confirmedTitle: 'You are on the list.',
        confirmedBody: 'We will write when there is something worth hearing. The list is ' +
            'run by hand, so there is no confirmation email to wait for.',
        confirmedBack: 'Back to SoundGraph',
        // Two headings, because there are two failures and they send you to different
        // places. "That did not connect" over a typo has you checking your wifi.
        errorTitle: 'That did not connect.',
        addressTitle: 'Check that address.',
        errorBody: 'Your patch is safe. Check the address or try joining again later.',
        errorRetry: 'Try again',
        errorBack: 'Return to SoundGraph',
    },
    resume: {
        question: 'Finish the two-minute introduction?',
        yes: 'Continue',
        no: 'Dismiss',
    },
    // When the engine never loaded, the patch has no control surfaces to drag and the
    // golden moment cannot happen. Saying so is the only honest move: a tour that carries
    // on to "you heard why" over a page with no controls has started lying to make its
    // funnel look better.
    unavailable: {
        title: 'The engine did not load.',
        body: 'The patch is here and the graph is drawn, but its controls come from the ' +
            'audio engine and that has not started. Reloading the page is usually enough. ' +
            'Everything else on this page still works.',
        done: 'Close the introduction',
    },
};

/** How much the cutoff has to move before it counts. One octave: enough that nobody can
 *  argue they did not hear it, small enough that a deliberate drag reaches it easily. */
export const GOLDEN_OCTAVES = 1.0;

/** Did this change earn the golden moment? Pure, so the threshold can be tested without a
 *  browser, an AudioContext or a person. */
export function isGoldenChange(originalHz, currentHz, octaves = GOLDEN_OCTAVES) {
    if (!(originalHz > 0) || !(currentHz > 0)) {
        return false;
    }
    return Math.abs(Math.log2(currentHz / originalHz)) >= octaves;
}

const reducedMotion = () =>
    window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;

// ---------------------------------------------------------------------------------
// Small DOM helpers
// ---------------------------------------------------------------------------------

function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function button(label, className, onClick) {
    const element = make('button', className, label);
    element.type = 'button';
    element.addEventListener('click', () => {
        element.blur();
        onClick();
    });
    return element;
}

// ---------------------------------------------------------------------------------
// The tour
//
// `host` is everything the tour is not allowed to know how to do itself. It is implemented
// in app.js, which owns the page:
//
//   startAudio()                    resolves when audio is running, rejects with a reason
//   audioRunning()                  boolean
//   stopAudio() / resumeAudio()
//   loadTutorialPatch()             resolves once the tutorial patch is applied
//   controlElement(id)              the <input type=range> for a control id
//   controlDescriptor(id)           the patch's own control entry
//   controlValue(id) / setControlValue(id, value)
//   focusNodes(ids | null)          graph attention
//   activeNode(id | null)           graph "this is where the change lands"
//   savePatchLocally()              returns true when it stuck
//   setBypass(on)                   structural lesson: filter in or out of the path
//   onMailingOffered()              the page's chance to react when the panel appears
// ---------------------------------------------------------------------------------

export class Onboarding {
    constructor(host) {
        this.host = host;
        this.silent = false;
        this.step = null;
        this.originalCutoff = null;
        this.changedCutoff = null;
        this.showingOriginal = false;
        this.bypassed = false;
        this.mailingOffered = false;
        this.watching = false;

        this.layer = make('div', 'tour-layer');
        this.layer.hidden = true;
        this.ring = make('div', 'tour-ring');
        this.ring.hidden = true;
        this.card = make('div', 'tour-card');
        this.card.setAttribute('role', 'dialog');
        this.card.setAttribute('aria-live', 'polite');
        this.card.hidden = true;
        this.modal = make('div', 'tour-modal');
        this.modal.hidden = true;

        this.layer.append(this.ring, this.card, this.modal);
        document.body.append(this.layer);

        this.reposition = () => this.placeCard();
        window.addEventListener('resize', this.reposition);
        window.addEventListener('scroll', this.reposition, { passive: true });

        // The funnel's most useful moment is the one on the way out. `pagehide` fires where
        // `unload` is unreliable and `beforeunload` is refused, and a keepalive fetch is the
        // only kind that survives it.
        window.addEventListener('pagehide', () => { flushFunnel({ keepalive: true }); });
        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'hidden') flushFunnel({ keepalive: true });
        });
    }

    // -------------------------------------------------------------------------------
    // Entry points
    // -------------------------------------------------------------------------------

    /** First visit, or a restart from Help. */
    start() {
        milestone(MILESTONES.ONBOARDING_STARTED);
        rememberProgress({ started: true, completed: false, skipped: false, step: 'arrival' });
        this.silent = false;
        this.showArrival();
    }

    /**
     * What a returning visitor gets. Never the tour itself: resuming an introduction over
     * an application somebody came back to use is the tour deciding it is more important
     * than the instrument. A small question is the most it may do.
     */
    offerResume() {
        const progress = onboardingProgress();
        if (progress.completed || progress.skipped || !progress.started) {
            return false;
        }
        this.showResumePrompt();
        return true;
    }

    restart() {
        this.dismissAll();
        this.start();
    }

    skip() {
        milestone(MILESTONES.ONBOARDING_SKIPPED);
        rememberProgress({ skipped: true, step: null });
        this.dismissAll();
        flushFunnel();
    }

    finish() {
        rememberProgress({ completed: true, step: null });
        this.dismissAll();
        flushFunnel();
    }

    dismissAll() {
        this.stopWatching();
        this.card.hidden = true;
        this.modal.hidden = true;
        this.ring.hidden = true;
        this.layer.hidden = true;
        this.step = null;
        document.body.removeAttribute('data-tour');
        this.host.focusNodes(null);
    }

    // -------------------------------------------------------------------------------
    // Presentation
    // -------------------------------------------------------------------------------

    show() {
        this.layer.hidden = false;
        document.body.setAttribute('data-tour', 'active');
    }

    /** The one blocking surface in the whole tour. */
    showModal(build) {
        this.show();
        this.card.hidden = true;
        this.ring.hidden = true;
        this.modal.hidden = false;
        this.modal.replaceChildren(build());
        this.modal.querySelector('button')?.focus();
    }

    /**
     * A card beside a ring. `target` is the element the card is talking about; passing null
     * puts the card in a corner, which is right for anything about the patch as a whole.
     */
    showCard(target, build) {
        this.show();
        this.modal.hidden = true;
        this.card.hidden = false;
        this.card.replaceChildren(build());
        this.target = target ?? null;

        // Bring it into view before pointing at it. On a 720-pixel window the cutoff slider
        // sits below the fold, so "drag this control to the right" arrived with the control
        // off screen and the card clamped to the top of the viewport pointing at nothing.
        //
        // Instant, not smooth. A smooth scroll is an animation, and the card and ring are
        // placed from a rect measured once — following it would depend on scroll events,
        // which browsers throttle to animation frames. Landing first and placing after is
        // both simpler and the only version with nothing to go out of step.
        this.target?.scrollIntoView({ block: 'center', behavior: 'auto' });
        this.placeCard();
    }

    placeCard() {
        if (this.card.hidden || !this.target?.isConnected) {
            this.ring.hidden = true;
            if (!this.card.hidden && !this.target) {
                this.card.classList.add('corner');
                this.card.style.removeProperty('top');
                this.card.style.removeProperty('left');
            }
            return;
        }
        this.card.classList.remove('corner');

        const box = this.target.getBoundingClientRect();
        this.ring.hidden = false;
        this.ring.style.top = `${box.top - 6}px`;
        this.ring.style.left = `${box.left - 6}px`;
        this.ring.style.width = `${box.width + 12}px`;
        this.ring.style.height = `${box.height + 12}px`;

        // Below the target when there is room, above when there is not, and never off the
        // side. Nothing cleverer: a coach mark that has to be scrolled to find is worse
        // than one in a slightly odd place.
        const card = this.card.getBoundingClientRect();
        const gap = 14;
        let top = box.bottom + gap;
        if (top + card.height > window.innerHeight - 8) {
            top = Math.max(8, box.top - card.height - gap);
        }
        let left = box.left;
        if (left + card.width > window.innerWidth - 8) {
            left = Math.max(8, window.innerWidth - card.width - 8);
        }
        this.card.style.top = `${top}px`;
        this.card.style.left = `${left}px`;
    }

    // -------------------------------------------------------------------------------
    // Step 1 — Arrival
    // -------------------------------------------------------------------------------

    showArrival() {
        this.step = 'arrival';
        this.showModal(() => {
            const panel = make('div', 'tour-panel arrival');
            panel.append(
                make('p', 'brandmark', COPY.arrival.title),
                make('h2', 'promise', COPY.arrival.promise),
                make('p', 'body', COPY.arrival.body),
            );

            const actions = make('div', 'tour-actions');
            actions.append(
                button(COPY.arrival.start, 'primary', () => this.beginAudio()),
                button(COPY.arrival.skip, 'quiet', () => this.skip()),
            );
            panel.append(actions, make('p', 'small-print', COPY.arrival.volume));
            return panel;
        });
    }

    async beginAudio() {
        for (const element of this.modal.querySelectorAll('button')) {
            element.disabled = true;
        }
        try {
            await this.host.startAudio();
            milestone(MILESTONES.AUDIO_STARTED);
            this.silent = false;
        } catch (error) {
            this.showAudioFailure(error);
            return;
        }
        await this.host.loadTutorialPatch();
        this.showHear();
    }

    showAudioFailure(error) {
        this.step = 'audio-failure';
        const copy = error?.kind === 'module' ? COPY.engineFailure : COPY.audioFailure;

        this.showModal(() => {
            const panel = make('div', 'tour-panel failure');
            panel.append(
                make('h2', 'promise', copy.title),
                make('p', 'body', copy.body),
            );
            const actions = make('div', 'tour-actions');
            actions.append(
                button(copy.retry, 'primary', () => this.beginAudio()),
                button(copy.silent, 'quiet', () => this.continueSilently()),
            );
            panel.append(actions);

            // What actually went wrong, verbatim and last. A visitor can ignore it; whoever
            // is looking at a broken deploy needs it, and asking them to open a console to
            // find out why the page said it had no sound is a poor trade.
            const detail = error?.message ?? String(error ?? '');
            if (detail) {
                panel.append(make('p', 'detail', detail));
            }
            return panel;
        });
    }

    async continueSilently() {
        this.silent = true;
        await this.host.loadTutorialPatch();
        this.showHear();
    }

    // -------------------------------------------------------------------------------
    // Step 2 — Hear the complete patch
    // -------------------------------------------------------------------------------

    showHear() {
        this.step = 'hear';
        rememberProgress({ step: 'hear' });
        this.host.focusNodes(null);

        this.showCard(this.host.graphElement(), () => {
            const panel = make('div', 'tour-panel');
            panel.append(
                make('h2', null, COPY.hear.title),
                make('p', 'body', this.silent ? COPY.hear.bodySilent : COPY.hear.body),
            );

            const actions = make('div', 'tour-actions');
            actions.append(button(this.silent ? COPY.hear.nextSilent : COPY.hear.next, 'primary', () => {
                if (!this.silent) milestone(MILESTONES.TUTORIAL_PATCH_HEARD);
                this.showRead();
            }));
            if (!this.silent) {
                let playing = true;
                const toggle = button(COPY.hear.stop, 'quiet', () => {
                    playing = !playing;
                    if (playing) this.host.resumeAudio(); else this.host.stopAudio();
                    toggle.textContent = playing ? COPY.hear.stop : COPY.hear.resume;
                });
                actions.append(toggle);
            }
            actions.append(this.skipLink());
            panel.append(actions);
            return panel;
        });
    }

    // -------------------------------------------------------------------------------
    // Step 3 — Read the signal
    // -------------------------------------------------------------------------------

    showRead() {
        this.step = 'read';
        rememberProgress({ step: 'read' });
        const instant = reducedMotion();

        this.showCard(this.host.graphElement(), () => {
            const panel = make('div', 'tour-panel');
            panel.append(make('h2', null, COPY.read.title));

            const list = make('ol', 'read-lines');
            const items = COPY.read.lines.map((line) => {
                const item = make('li', instant ? 'shown' : null, line.text);
                list.append(item);
                return item;
            });
            panel.append(list);

            const actions = make('div', 'tour-actions');
            actions.append(
                button(COPY.read.next, 'primary', () => this.showInvite()),
                this.skipLink(),
            );
            panel.append(actions);

            if (instant) {
                this.host.focusNodes(null);
            } else {
                // One sentence at a time, with the graph following. Skippable throughout —
                // the button above is live from the first frame, and leaving stops the timer.
                let index = 0;
                const advance = () => {
                    if (this.step !== 'read' || index >= items.length) {
                        if (this.step === 'read') this.host.focusNodes(null);
                        return;
                    }
                    items[index].classList.add('shown');
                    this.host.focusNodes(COPY.read.lines[index].nodes);
                    index += 1;
                    this.readTimer = window.setTimeout(advance, 1700);
                };
                window.clearTimeout(this.readTimer);
                advance();
            }
            return panel;
        });
    }

    // -------------------------------------------------------------------------------
    // Step 4 — Invite the first change
    //
    // No Next button, on purpose. The change is the next step, and offering a way past it
    // would turn the one moment this whole page is built around into something optional.
    // -------------------------------------------------------------------------------

    showInvite() {
        this.step = 'invite';
        rememberProgress({ step: 'invite' });
        window.clearTimeout(this.readTimer);

        const slider = this.host.controlElement('cutoff');
        if (!slider) {
            this.showUnavailable();
            return;
        }
        this.originalCutoff = this.host.controlValue('cutoff');
        this.host.focusNodes(['filter']);
        this.host.activeNode('filter');

        this.showCard(slider, () => {
            const panel = make('div', 'tour-panel');
            panel.append(
                make('h2', null, COPY.invite.title),
                make('p', 'body', this.silent ? COPY.invite.bodySilent : COPY.invite.body),
                make('p', 'prompt', COPY.invite.prompt),
            );
            const actions = make('div', 'tour-actions');
            actions.append(this.skipLink());
            panel.append(actions);
            return panel;
        });

        this.startWatching();
    }

    startWatching() {
        const slider = this.host.controlElement('cutoff');
        if (!slider || this.watching) return;
        this.onSliderInput = () => this.checkGolden();
        slider.addEventListener('input', this.onSliderInput);
        this.watching = true;
    }

    stopWatching() {
        const slider = this.host.controlElement('cutoff');
        if (slider && this.onSliderInput) {
            slider.removeEventListener('input', this.onSliderInput);
        }
        this.watching = false;
    }

    checkGolden() {
        const current = this.host.controlValue('cutoff');
        milestone(MILESTONES.FIRST_PARAMETER_CHANGED);
        if (!isGoldenChange(this.originalCutoff, current)) {
            return;
        }
        this.changedCutoff = current;
        this.stopWatching();
        this.showGolden();
    }

    // -------------------------------------------------------------------------------
    // Step 5 — Golden moment
    // -------------------------------------------------------------------------------

    showGolden() {
        this.step = 'golden';
        rememberProgress({ step: 'golden' });
        // Recorded only when it is true. A silent visitor changed the graph and saw the
        // filter light up; they did not hear why, and this milestone says they did.
        if (!this.silent) {
            milestone(MILESTONES.GOLDEN_MOMENT_COMPLETED);
            flushFunnel();
        }
        this.showingOriginal = false;

        this.showCard(this.host.controlElement('cutoff'), () => {
            const panel = make('div', 'tour-panel');
            panel.append(
                make('h2', null, this.silent ? COPY.golden.titleSilent : COPY.golden.title),
                make('p', 'body', COPY.golden.body),
            );

            const state = make('p', 'compare-state', COPY.golden.yours);
            panel.append(state);

            const actions = make('div', 'tour-actions');
            const compare = button(COPY.golden.compare, 'quiet', () => {
                this.showingOriginal = !this.showingOriginal;
                this.host.setControlValue(
                    'cutoff',
                    this.showingOriginal ? this.originalCutoff : this.changedCutoff,
                );
                state.textContent = this.showingOriginal ? COPY.golden.original : COPY.golden.yours;
            });
            actions.append(
                compare,
                button(COPY.golden.keep, 'primary', () => {
                    // Whatever is on screen when they say "keep" is what they keep — if the
                    // toggle is showing the original and they prefer it, that is a choice.
                    this.showAgency();
                }),
            );
            panel.append(actions);
            return panel;
        });
    }

    // -------------------------------------------------------------------------------
    // Step 6 — Agency
    // -------------------------------------------------------------------------------

    showAgency() {
        this.step = 'agency';
        this.host.focusNodes(null);
        rememberProgress({ completed: true, step: 'agency' });

        this.showCard(null, () => {
            const panel = make('div', 'tour-panel');
            panel.append(make('h2', null, COPY.agency.title), make('p', 'body', COPY.agency.intro));

            const list = make('ul', 'agency-list');
            for (const item of COPY.agency.items) {
                list.append(make('li', null, item));
            }
            panel.append(list);

            const actions = make('div', 'tour-actions');
            actions.append(
                button(COPY.agency.keepGoing, 'primary', () => {
                    this.finish();
                    this.offerMailingList();
                }),
                button(COPY.agency.save, 'quiet', () => {
                    if (this.host.savePatchLocally()) {
                        milestone(MILESTONES.PATCH_SAVED);
                    }
                    this.finish();
                    this.offerMailingList();
                }),
            );
            panel.append(actions);

            const more = button(COPY.agency.more, 'link', () => this.showStructural());
            panel.append(more);
            return panel;
        });
    }

    // -------------------------------------------------------------------------------
    // One more thing — exactly one structural action, and then it stops
    // -------------------------------------------------------------------------------

    showStructural() {
        this.step = 'structural';
        this.host.focusNodes(['osc', 'filter', 'amp']);

        const render = (note) => this.showCard(this.host.graphElement(), () => {
            const panel = make('div', 'tour-panel');
            panel.append(
                make('h2', null, COPY.structural.title),
                make('p', 'body', COPY.structural.body),
            );
            if (note) panel.append(make('p', 'prompt', note));

            const actions = make('div', 'tour-actions');
            actions.append(button(
                this.bypassed ? COPY.structural.restore : COPY.structural.bypass,
                'primary',
                () => {
                    this.bypassed = !this.bypassed;
                    this.host.setBypass(this.bypassed);
                    render(this.bypassed ? COPY.structural.bypassed : COPY.structural.restored);
                },
            ));
            actions.append(button(COPY.structural.done, 'quiet', () => {
                this.finish();
                this.offerMailingList();
            }));
            panel.append(actions);
            return panel;
        });

        render(null);
    }

    showUnavailable() {
        this.step = 'unavailable';
        this.host.focusNodes(null);
        this.showCard(null, () => {
            const panel = make('div', 'tour-panel');
            panel.append(
                make('h2', null, COPY.unavailable.title),
                make('p', 'body', COPY.unavailable.body),
            );
            const actions = make('div', 'tour-actions');
            actions.append(button(COPY.unavailable.done, 'primary', () => {
                // Not `finish()`: nothing was completed, and recording it as completed
                // would mean this visitor never sees the introduction again.
                this.dismissAll();
                flushFunnel();
            }));
            panel.append(actions);
            return panel;
        });
    }

    skipLink() {
        return button('Skip the tour', 'link', () => this.skip());
    }

    // -------------------------------------------------------------------------------
    // The mailing list
    //
    // Reachable from exactly one place: after the golden moment, once the visitor has
    // chosen to continue. It is a panel, not a modal — the instrument stays usable behind
    // it, and declining costs nothing.
    // -------------------------------------------------------------------------------

    offerMailingList() {
        if (this.mailingOffered || mailingState().answered) {
            return false;
        }
        this.mailingOffered = true;
        this.openMailingList();
        return true;
    }

    /**
     * The panel, unconditionally. This is what the "Join the mailing list" button in the
     * actions bar calls, and the gate above deliberately does not apply to it: the gate
     * exists so the page never asks before it has given anything, not to argue with
     * somebody who came looking for the form.
     */
    openMailingList() {
        milestone(MILESTONES.EMAIL_PROMPT_SHOWN);
        this.host.onMailingOffered?.();
        this.renderMailingPanel();
    }

    closeMailing() {
        this.mailingPanel?.remove();
        this.mailingPanel = null;
        flushFunnel();
    }

    renderMailingPanel(state = { phase: 'form', message: null }) {
        this.mailingPanel?.remove();

        const panel = make('aside', 'mailing-panel');
        panel.setAttribute('aria-label', COPY.mailing.title);

        if (state.phase === 'done') {
            panel.append(
                make('h2', null, COPY.mailing.confirmedTitle),
                make('p', 'body', COPY.mailing.confirmedBody),
            );
            const actions = make('div', 'tour-actions');
            actions.append(button(COPY.mailing.confirmedBack, 'primary', () => this.closeMailing()));
            panel.append(actions);
        } else if (state.phase === 'error') {
            panel.append(
                make('h2', null,
                    state.kind === 'address' ? COPY.mailing.addressTitle : COPY.mailing.errorTitle),
                make('p', 'body', state.message ?? COPY.mailing.errorBody),
            );
            const actions = make('div', 'tour-actions');
            actions.append(
                button(COPY.mailing.errorRetry, 'primary', () => this.renderMailingPanel()),
                button(COPY.mailing.errorBack, 'quiet', () => {
                    rememberMailing({ answered: true, joined: false });
                    this.closeMailing();
                }),
            );
            panel.append(actions);
        } else {
            panel.append(
                make('h2', null, COPY.mailing.title),
                make('p', 'body', COPY.mailing.body),
            );

            const form = make('form', 'mailing-form');
            const label = make('label', null, COPY.mailing.label);
            const field = document.createElement('input');
            field.type = 'email';
            field.name = 'email';
            field.autocomplete = 'email';
            field.required = true;
            field.id = 'mailing-address';
            label.htmlFor = field.id;

            const submit = make('button', 'primary', COPY.mailing.submit);
            submit.type = 'submit';

            form.append(label, field, submit);
            form.addEventListener('submit', async (event) => {
                event.preventDefault();
                submit.disabled = true;
                submit.textContent = COPY.mailing.working;
                const result = await joinMailingList(field.value);
                if (result.ok) {
                    milestone(MILESTONES.EMAIL_SIGNUP_SUBMITTED);
                    rememberMailing({ answered: true, joined: true });
                    flushFunnel();
                    this.renderMailingPanel({ phase: 'done' });
                } else {
                    this.renderMailingPanel({ phase: 'error', message: result.message, kind: result.kind });
                }
            });
            panel.append(form);

            const actions = make('div', 'tour-actions');
            actions.append(button(COPY.mailing.decline, 'quiet', () => {
                rememberMailing({ answered: true, joined: false });
                this.closeMailing();
            }));
            panel.append(actions, make('p', 'small-print', COPY.mailing.smallPrint));
        }

        document.body.append(panel);
        this.mailingPanel = panel;
        panel.querySelector('input, button')?.focus();
    }

    // -------------------------------------------------------------------------------
    // Returning visitor
    // -------------------------------------------------------------------------------

    showResumePrompt() {
        const panel = make('aside', 'resume-panel');
        panel.append(make('p', 'body', COPY.resume.question));

        const actions = make('div', 'tour-actions');
        actions.append(
            button(COPY.resume.yes, 'primary', () => {
                panel.remove();
                this.start();
            }),
            button(COPY.resume.no, 'quiet', () => {
                panel.remove();
                rememberProgress({ skipped: true });
            }),
        );
        panel.append(actions);
        document.body.append(panel);
    }
}
