#!/usr/bin/env node
// Writes a build stamp: what this build came from and when.
//
//   node tools/stamp-build.mjs [--target web|desktop|web-editor]
//
// `web` and `desktop` stamp the Godot editor. `web-editor` stamps editor-web, which needs
// one for a different reason: it is the `app_version` on every report that page sends, and
// the feedback envelope is blunt about it — a report you cannot pin to an exact build is
// close to worthless. Same file, same shape, same reason not to commit it.
//
// "Am I running a stale build" is not a question anyone should have to answer by
// reasoning about their browser cache. It is especially not answerable for the web
// export, where a reload can serve a bundle from last week and look exactly like a
// reload that served one from a minute ago.
//
// The stamp is deliberately *not* committed. A checked-in stamp is a stamp that is
// wrong the moment anybody commits anything else, and a build stamp that lies is worse
// than no build stamp: it converts "I am not sure what I am running" into "I am sure,
// and mistaken". Absent, the app says "development build", which is the truth when you
// are running from source.

import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const targetIndex = process.argv.indexOf('--target');
const target = targetIndex >= 0 ? process.argv[targetIndex + 1] : 'desktop';

const out = target === 'web-editor'
    ? join(root, 'editor-web', 'build_stamp.json')
    : join(root, 'editor-godot', 'build_stamp.json');

// Every git call is allowed to fail: a tarball with no .git is a legitimate way to have
// this source, and the stamp should degrade to "what it could find out" rather than
// taking the build down with it.
const git = (...args) => {
  try {
    return execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
};

const describe = git('describe', '--tags', '--always', '--dirty');
const commit = git('rev-parse', '--short', 'HEAD');
const dirty = describe.endsWith('-dirty') || git('status', '--porcelain') !== '';

// "v0.1.1-13-gdd1b1f8" is what git says; "v0.1.1+13" is what a person reads. Composed
// here rather than in the editor, which should be displaying a stamp rather than
// parsing one.
let short = describe.replace(/-dirty$/, '');
const described = /^(.*)-(\d+)-g[0-9a-f]+$/.exec(short);
if (described !== null) {
  short = Number(described[2]) === 0 ? described[1] : `${described[1]}+${described[2]}`;
}
if (short === '') short = commit || 'unknown';
if (dirty) short += '*';

const now = new Date();
const stamp = {
  short,
  describe: describe || 'unknown',
  commit: commit || 'unknown',
  dirty,
  target,
  built_unix: Math.floor(now.getTime() / 1000),
  built_utc: now.toISOString().replace(/\.\d+Z$/, 'Z'),
};

writeFileSync(out, JSON.stringify(stamp, null, 2) + '\n');
console.log(`stamped ${short} (${target}, ${stamp.built_utc})`);
