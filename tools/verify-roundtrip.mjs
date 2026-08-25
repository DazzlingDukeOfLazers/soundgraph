// Milestone C's exit condition: a patch edited in one editor opens in the other and still
// means the same thing.
//
//   node tools/verify-roundtrip.mjs
//
// "Means the same thing" is checked by rendering, not by comparing text. Two patch files
// can differ in key order, number formatting and whitespace while describing an identical
// graph — and can just as easily look similar while describing different ones. So each
// patch is pushed through the Godot editor's real load-and-save path, then both the
// original and the result are rendered with sg-render and compared sample by sample.
//
// Exits non-zero if any patch fails to survive, so it can be a build step.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

// game/jump.json earns its place by being generated rather than hand-written: it is the
// one that uses whatever the mapper emitted most recently, so it is the one that notices
// when the editor and the mapper disagree about a port that only just started existing.
const PATCHES = ['first-synth.json', 'delay-echo.json', 'game/jump.json'];
const RENDER_SECONDS = 2;
const NOTES = '45,52,57';

// Godot is found the same way the gate finds it, which it previously was not. This read
// only `GODOT`, while tools/pre-push.sh reads `SOUNDGRAPH_GODOT` then `git config
// soundgraph.godot`, and tools/export-web.mjs reads `SOUNDGRAPH_GODOT` then `--godot`.
// Three spellings for one answer, and setting the wrong one here does not say so: the
// hard-coded fallback below has moved, `godot` is not on the PATH under that name on
// Windows, and execFileSync on a command that does not exist reports `status: null` — the
// same thing it reports for a timeout. All three patches then "could not round trip",
// which reads like the editor mangling them rather than Godot never having run at all.
function findGodot() {
    if (process.env.SOUNDGRAPH_GODOT) return process.env.SOUNDGRAPH_GODOT;
    if (process.env.GODOT) return process.env.GODOT;

    try {
        const configured = execFileSync('git', ['config', '--get', 'soundgraph.godot'],
            { cwd: repoRoot, encoding: 'utf8' }).trim();
        if (configured) return configured;
    } catch {
        // No such setting, or no git. Fall through to looking for it.
    }

    const candidates = [
        'C:\\Users\\danie\\Downloads\\gofo\\Godot_v4.7.1-stable_win64.exe\\Godot_v4.7.1-stable_win64_console.exe',
        'C:\\Users\\danie\\Downloads\\gofo\\Godot_v4.7.1-stable_win64.exe\\Godot_v4.7.1-stable_win64.exe',
        // What winget installs it as. `godot` is not one of the names it ships under.
        process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, 'Microsoft', 'WinGet',
            'Packages', 'GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe',
            'Godot_v4.7.1-stable_win64_console.exe'),
        'godot',
    ].filter(Boolean);

    for (const candidate of candidates) {
        if (candidate === 'godot' || existsSync(candidate)) return candidate;
    }
    return null;
}

function findRenderer() {
    for (const name of ['sg-render.exe', 'sg-render']) {
        const path = join(repoRoot, 'build', 'bin', name);
        if (existsSync(path)) return path;
    }
    return null;
}

function readFloatWav(path) {
    const bytes = readFileSync(path);
    let position = 12;
    let format = 0;
    let bits = 0;
    while (position + 8 <= bytes.length) {
        const id = bytes.toString('ascii', position, position + 4);
        const size = bytes.readUInt32LE(position + 4);
        const body = position + 8;
        if (id === 'fmt ') {
            format = bytes.readUInt16LE(body);
            bits = bytes.readUInt16LE(body + 14);
        } else if (id === 'data') {
            if (format !== 3 || bits !== 32) {
                throw new Error(`${path}: expected 32-bit float PCM`);
            }
            const samples = new Float32Array(size / 4);
            for (let i = 0; i < samples.length; i += 1) samples[i] = bytes.readFloatLE(body + i * 4);
            return samples;
        }
        position = body + size + (size & 1);
    }
    throw new Error(`${path}: no data chunk`);
}

function render(renderer, patchPath, wavPath) {
    execFileSync(renderer, [
        patchPath, wavPath,
        '--seconds', String(RENDER_SECONDS),
        '--notes', NOTES,
        '--float', '--quiet',
    ], { stdio: 'pipe' });
    return readFloatWav(wavPath);
}

const godot = findGodot();
const renderer = findRenderer();

if (!renderer) {
    console.error('sg-render not found — build the native tree first:\n' +
        '  cmake -S . -B build && cmake --build build');
    process.exit(1);
}
if (!godot) {
    console.error('Godot not found. Set GODOT to the executable path.');
    process.exit(1);
}

const work = mkdtempSync(join(tmpdir(), 'soundgraph-roundtrip-'));
let failures = 0;

console.log('Round tripping patches through the Godot editor and comparing rendered audio.\n');

try {
    // Import once, first. A Godot project whose files changed since the last run does an
    // import pass on the next launch, and a --script run that collides with that can fail
    // with nothing useful on stderr — which is what this reported, four times in a row,
    // right after the example patches were regenerated. Doing it deliberately and once is
    // cheaper than a confusing failure that clears itself up.
    try {
        execFileSync(godot, ['--headless', '--path', join(repoRoot, 'editor-godot'), '--import'],
            { stdio: 'pipe', timeout: 180000 });
    } catch {
        // An import that fails is not itself the thing under test; the round trips below
        // will say so far more clearly.
    }

    for (const name of PATCHES) {
        const original = join(repoRoot, 'examples', 'patches', name);
        // Flattened, because a patch named game/jump.json would otherwise want a
        // subdirectory in the scratch dir that nothing creates, and the editor's failure
        // to write there reads exactly like a refusal to round trip the patch.
        const tripped = join(work, `tripped-${name.replace(/[\\/]/g, '-')}`);

        try {
            execFileSync(godot, [
                '--headless',
                '--path', join(repoRoot, 'editor-godot'),
                '--script', 'res://roundtrip.gd',
                '--', original, tripped,
            ], { stdio: 'pipe', timeout: 120000 });
        } catch (error) {
            // 0xC0000005 is a crash, and saying so matters: it comes with nothing on
            // either stream, so it reads exactly like the editor quietly refusing the
            // patch and sent me chasing three imaginary bugs in the teardown path
            // before I measured an older commit and found the fault was newer than
            // the code I was blaming. Named, it is at least the right question.
            const crashed = error.status === 3221225477;
            console.log(`  FAIL ${name}: ` + (crashed
                ? `the editor CRASHED at exit (0xC0000005) — see docs/current-phase.md;`
                    + ` the patch itself may well have round tripped`
                : `the editor could not round trip it (exit status ${error.status})`));
            const detail = (error.stderr || error.stdout || '').toString().trim();
            if (detail) console.log(detail.split('\n').map((l) => `         ${l}`).join('\n'));
            failures += 1;
            continue;
        }

        if (!existsSync(tripped)) {
            console.log(`  FAIL ${name}: the editor wrote no output`);
            failures += 1;
            continue;
        }

        const before = render(renderer, original, join(work, 'before.wav'));
        const after = render(renderer, tripped, join(work, 'after.wav'));

        if (before.length !== after.length) {
            console.log(`  FAIL ${name}: rendered lengths differ`);
            failures += 1;
            continue;
        }

        let worst = 0;
        let worstIndex = 0;
        for (let i = 0; i < before.length; i += 1) {
            const difference = Math.abs(before[i] - after[i]);
            if (difference > worst) {
                worst = difference;
                worstIndex = i;
            }
        }

        // A round trip is not an approximation. The same graph rendered twice by the same
        // binary must be identical; anything else means the editor changed the patch.
        if (worst !== 0) {
            console.log(`  FAIL ${name}: audio changed by ${worst.toExponential(2)} at sample ${worstIndex}`);
            failures += 1;
            continue;
        }

        const originalJson = JSON.parse(readFileSync(original, 'utf8'));
        const trippedJson = JSON.parse(readFileSync(tripped, 'utf8'));
        const nodeCount = trippedJson.nodes.length;
        const kept = ['controls', 'automation', 'metadata']
            .filter((key) => originalJson[key] !== undefined)
            .map((key) => {
                const before = Array.isArray(originalJson[key])
                    ? originalJson[key].length : Object.keys(originalJson[key]).length;
                const after = trippedJson[key] === undefined ? 0
                    : (Array.isArray(trippedJson[key])
                        ? trippedJson[key].length : Object.keys(trippedJson[key]).length);
                if (before !== after) failures += 1;
                return `${key} ${after}/${before}`;
            });

        const lost = kept.filter((entry) => {
            const [, ratio] = entry.split(' ');
            const [after, before] = ratio.split('/');
            return after !== before;
        });

        if (lost.length > 0) {
            console.log(`  FAIL ${name}: the editor dropped ${lost.join(', ')}`);
            continue;
        }

        console.log(`  ok   ${name.padEnd(18)} identical audio, ${nodeCount} nodes, ${kept.join(', ')}`);
    }
} finally {
    rmSync(work, { recursive: true, force: true });
}

console.log('');
if (failures > 0) {
    console.log(`${failures} patch(es) did not survive the round trip.`);
    process.exit(1);
}
console.log('Every patch survived the round trip with identical audio.');
