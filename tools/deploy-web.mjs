#!/usr/bin/env node
// Puts the web funnel on Cloudflare: the editor export into R2, then the Worker (with
// the marketing page bundled as its static assets) onto mutantfactory.com/soundgraph*.
//
//   node tools/deploy-web.mjs [--skip-upload]
//
// Needs a logged-in wrangler (`npx wrangler login`, once per machine). The editor export
// must exist first — this script checks rather than exports, because exporting needs
// Godot and deploying should not.
//
// The public shape this produces (see tools/cloudflare/worker.js for the whole map):
//
//   mutantfactory.com/soundgraph/             the page
//   mutantfactory.com/soundgraph/editor-web/  the full editor, out of R2
//   mutantfactory.com/soundgraph/editor/      301 → editor-web/, so the page's relative
//                                             './editor/' links work unchanged
//   mutantfactory.com/examples/patches/       the example patches, out of the same bucket
//
// Every file re-uploads every run (~53 MB). A few dozen files is not worth a manifest;
// the day that stops being true, diff etags instead.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const editorDir = join(root, 'editor-web', 'editor');
const config = join(root, 'tools', 'cloudflare', 'wrangler.toml');
const BUCKET = 'soundgraph-editor';

// Streaming wasm compilation and Cloudflare's on-the-fly brotli both key off the
// Content-Type, so getting application/wasm right is what turns 44 MB into ~12 on the
// wire. Everything unlisted ships as plain bytes.
const TYPES = {
  '.wasm': 'application/wasm',
  '.js': 'text/javascript',
  '.html': 'text/html;charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function wrangler(args) {
  // npx resolves wrangler without making it a checked-in dependency; shell:true is what
  // finds npx.cmd on Windows.
  execFileSync('npx', ['wrangler', ...args], { stdio: 'inherit', shell: true, cwd: root });
}

if (!existsSync(join(editorDir, 'index.side.wasm'))) {
  console.error('No editor export at editor-web/editor — the funnel would deploy with a '
    + 'dead "Open the full editor" link.\n'
    + '  Run: node tools/export-web.mjs --out editor-web/editor');
  process.exit(1);
}

if (!process.argv.includes('--skip-upload')) {
  // Idempotent by intent: create fails when the bucket exists, and that is fine.
  try {
    wrangler(['r2', 'bucket', 'create', BUCKET]);
  } catch { /* already there */ }

  const walk = (dir, prefix = '') => readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory()
      ? walk(full, `${prefix}${name}/`)
      : [{ full, key: `${prefix}${name}` }];
  });

  const upload = ({ full, key }) => {
    const type = TYPES[extname(key)] ?? 'application/octet-stream';
    console.log(`\n→ ${key} (${type})`);
    wrangler(['r2', 'object', 'put', `${BUCKET}/${key}`,
      `--file=${full}`, `--content-type=${type}`, '--remote']);
  };

  walk(editorDir).forEach(upload);

  // The example patches too: the page fetches them at '../examples/patches/', one
  // directory above itself just as in the repository, so in production they come out of
  // this same bucket under 'patches/' (see tools/cloudflare/worker.js). Without them
  // the deployed page loads and then has nothing to play.
  //
  // The page's own source is the manifest. examples/patches holds ~300 files and the
  // page can only ask for the ones its code names, so uploading anything else is a
  // slower deploy for nobody — and reading the list out of app.js means adding an
  // example there is the whole job. A named file that does not exist stops the deploy,
  // which is the same 404 caught a visit early.
  const appSource = readFileSync(join(root, 'editor-web', 'app.js'), 'utf8');
  const named = [...new Set(appSource.match(/\.\.\/examples\/patches\/[^'"]+\.json/g))];
  for (const reference of named) {
    const relative = reference.slice('../examples/patches/'.length);
    const full = join(root, 'examples', 'patches', relative);
    if (!existsSync(full)) {
      console.error(`app.js names ${reference}, which does not exist.`);
      process.exit(1);
    }
    upload({ full, key: `patches/${relative}` });
  }
}

wrangler(['deploy', '--config', config]);
console.log('\nDeployed. The page: https://mutantfactory.com/soundgraph/'
  + '\nThe editor:          https://mutantfactory.com/soundgraph/editor-web/');
