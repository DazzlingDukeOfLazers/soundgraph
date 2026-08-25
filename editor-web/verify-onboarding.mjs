#!/usr/bin/env node
// Checks the parts of the onboarding that can be wrong without anybody noticing.
//
//   node editor-web/verify-onboarding.mjs
//
// The tour is mostly DOM, and DOM is checked by looking at it. What is checked here is the
// part that is not: the agreements between three files that are edited at different times
// by different people.
//
//   * The tour names nodes — `filter`, `osc`, `clock` — and those names live in a patch
//     file. Renaming a node in examples/patches/start-here.json would leave the tour
//     highlighting nothing at all, with no error anywhere: the ring would simply light up
//     an empty set and the visitor would be told to look at something invisible.
//
//   * The golden moment needs the cutoff control to have room to move a full octave from
//     where it starts. Narrow that control's range in the patch and the one interaction
//     this entire page is built around silently becomes unreachable.
//
//   * The milestone names are the measurement plan. A typo makes a row that never matches
//     a query, which looks exactly like a step nobody reached.
//
// Dependency-free, and it imports the real modules rather than a copy of their constants —
// a check that restates the thing it is checking is a check that passes forever.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const { COPY, GOLDEN_OCTAVES, isGoldenChange } = await import('./onboarding.js');
const { MILESTONES, browserFamily, funnelText, looksLikeAddress } = await import('./reporting.js');
const { GraphView } = await import('./graph-view.js');

const patch = JSON.parse(readFileSync(join(root, 'examples', 'patches', 'start-here.json'), 'utf8'));

let failures = 0;

function check(name, condition, detail = '') {
    if (condition) {
        console.log(`  ok   ${name}`);
    } else {
        console.log(`  FAIL ${name}${detail ? `: ${detail}` : ''}`);
        failures += 1;
    }
}

// ---------------------------------------------------------------------------------
// The tour and the patch agree about what is in the patch
// ---------------------------------------------------------------------------------

console.log('the tour and examples/patches/start-here.json');

const nodeIds = new Set(patch.nodes.map((node) => node.id));
const named = [...new Set(COPY.read.lines.flatMap((line) => line.nodes))];
const missing = named.filter((id) => !nodeIds.has(id));
check('every node the tour points at exists', missing.length === 0,
    `the tour names ${missing.join(', ')}, which the patch does not contain`);

const covered = new Set(named);
const uncovered = [...nodeIds].filter((id) => !covered.has(id));
check('every node in the patch is accounted for by a sentence', uncovered.length === 0,
    `${uncovered.join(', ')} is drawn but never explained`);

check('the tour tells the story in four sentences', COPY.read.lines.length === 4,
    `${COPY.read.lines.length} sentences`);

const filter = patch.nodes.find((node) => node.id === 'filter');
check('the node the tour calls the filter is a filter',
    filter?.type === 'StateVariableFilter', `it is a ${filter?.type}`);

// ---------------------------------------------------------------------------------
// The golden moment is reachable
// ---------------------------------------------------------------------------------

console.log('');
console.log('the golden moment');

const cutoff = (patch.controls ?? []).find((control) => control.id === 'cutoff');
check('the patch exposes a control with id "cutoff"', cutoff !== undefined);
check('it drives the filter node the tour highlights',
    cutoff?.target.node === 'filter' && cutoff?.target.parameter === 'cutoff',
    `it drives ${cutoff?.target.node}.${cutoff?.target.parameter}`);
check('it is the first control, so it is the first thing on the panel',
    patch.controls[0]?.id === 'cutoff', `the first control is ${patch.controls[0]?.id}`);

// "Drag it to the right" has to be enough on its own. Room below matters too — a visitor
// who drags the other way should reach the moment as well.
const start = cutoff?.default ?? 0;
check(`there is a full octave above the default (${GOLDEN_OCTAVES} needed)`,
    isGoldenChange(start, cutoff?.max), `${start} Hz to ${cutoff?.max} Hz is not enough`);
check('there is a full octave below the default',
    isGoldenChange(start, cutoff?.min), `${start} Hz to ${cutoff?.min} Hz is not enough`);

check('a nudge is not the golden moment', isGoldenChange(420, 460) === false);
check('doubling is', isGoldenChange(420, 840) === true);
check('halving is too', isGoldenChange(420, 210) === true);
check('nonsense is not', isGoldenChange(0, 840) === false && isGoldenChange(420, 0) === false);

// ---------------------------------------------------------------------------------
// The structural lesson has something to bypass
// ---------------------------------------------------------------------------------

console.log('');
console.log('the structural lesson');

const intoFilter = patch.connections.find((c) => c.to.node === 'filter' && c.to.port === 'in');
const outOfFilter = patch.connections.find((c) => c.from.node === 'filter');
check('something reaches the filter', intoFilter !== undefined);
check('the filter reaches something', outOfFilter !== undefined);
check('bypassing it would join two different nodes',
    intoFilter?.from.node !== outOfFilter?.to.node,
    'the filter is in a loop with itself');

// ---------------------------------------------------------------------------------
// The measurement plan
// ---------------------------------------------------------------------------------

console.log('');
console.log('the measurement plan');

const PLANNED = [
    'onboarding_started',
    'audio_started',
    'tutorial_patch_heard',
    'first_parameter_changed',
    'onboarding_golden_moment_completed',
    'patch_saved',
    'second_patch_loaded',
    'email_prompt_shown',
    'email_signup_submitted',
    'onboarding_skipped',
];
const declared = Object.values(MILESTONES);
check('every planned milestone is spelled exactly once',
    PLANNED.every((name) => declared.includes(name)) && declared.length === PLANNED.length,
    `declared: ${declared.join(', ')}`);

check('the funnel line names the steps in order',
    funnelText([{ name: 'onboarding_started', at_ms: 0 }, { name: 'audio_started', at_ms: 2400 }])
        === 'onboarding funnel: onboarding_started@0s -> audio_started@2.4s');
check('an empty funnel says so', funnelText([]).includes('nothing happened'));

// ---------------------------------------------------------------------------------
// Two small things that are easy to get backwards
// ---------------------------------------------------------------------------------

console.log('');
console.log('reporting details');

// Every browser below also says "Safari" in its user agent, so the order of the tests
// inside browserFamily is load-bearing.
check('Chrome is not reported as Safari',
    browserFamily('Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 (KHTML, like Gecko) ' +
        'Chrome/140.0.0.0 Safari/537.36') === 'web/Chrome');
check('Edge is not reported as Chrome',
    browserFamily('Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 (KHTML, like Gecko) ' +
        'Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0') === 'web/Edge');
check('Safari is reported as Safari',
    browserFamily('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 ' +
        '(KHTML, like Gecko) Version/18.0 Safari/605.1.15') === 'web/Safari');
check('Firefox is reported as Firefox',
    browserFamily('Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0')
        === 'web/Firefox');
check('an address with no domain is refused', looksLikeAddress('someone@localhost') === false);
check('an ordinary address is accepted', looksLikeAddress('someone@example.com') === true);
check('an empty field is refused', looksLikeAddress('') === false);

// ---------------------------------------------------------------------------------
// The picture
// ---------------------------------------------------------------------------------

console.log('');
console.log('the graph view');

const view = new GraphView(null);
view.patch = patch;
view.layout(patch);
check('every node is placed', view.boxes.size === patch.nodes.length);

// Two cables leaving the same node must not leave from the same point, or the picture
// says one cable where the patch has two.
const clockGate = view.anchor('clock', 'gate', 'out');
const seqClock = view.anchor('seq', 'clock', 'in');
const envGate = view.anchor('env', 'gate', 'in');
check('a cable has somewhere to start and somewhere to land',
    clockGate !== null && seqClock !== null && envGate !== null);

const description = view.describe(patch);
const unnamed = patch.nodes.filter((node) => !description.includes(node.name || node.type));
check('the spoken description names every node', unnamed.length === 0,
    `missing ${unnamed.map((node) => node.id).join(', ')}`);
// Every node must be named after everything that feeds it. The first version of describe()
// walked breadth-first and announced the amplifier before the filter — two cables from the
// clock along the envelope beats three along the audio — so the one account of the graph a
// screen reader gets had the signal running backwards through half the patch.
const labelOf = (id) => {
    const node = patch.nodes.find((candidate) => candidate.id === id);
    return node.name || node.type || id;
};
const backwards = patch.connections.filter((c) =>
    description.indexOf(labelOf(c.from.node)) > description.indexOf(labelOf(c.to.node)));
check('nothing is named before the thing feeding it', backwards.length === 0,
    `${backwards.map((c) => `${c.from.node}->${c.to.node}`).join(', ')} in "${description}"`);

// ---------------------------------------------------------------------------------

console.log('');
if (failures > 0) {
    console.log(`${failures} onboarding check(s) failed.`);
    process.exit(1);
}
console.log('The onboarding, the patch it teaches and the measurement plan agree.');
