#!/usr/bin/env node
// Checks the committed patches against schema/patch.schema.json.
//
// The schema is the written-down version of the format, and until now nothing compared it
// to anything. It could say a field was required that no patch had, or forbid one every
// patch carried, and the only symptom would be somebody outside this repository writing a
// tool against it and finding it wrong. `host` was added to it by hand and no test would
// have noticed a mistake.
//
// Dependency-free on purpose: this repository has no package.json and no node_modules, and
// pulling in a validator to check one file would be a larger commitment than the check is
// worth. The schema uses a small, closed set of keywords — the ones below — and a new one
// is reported rather than ignored, so the checker cannot quietly stop checking.
//
//   node tools/schema-check.mjs

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const schema = JSON.parse(readFileSync(join(root, "schema", "patch.schema.json"), "utf8"));

const KNOWN = new Set([
  "$schema", "$id", "$defs", "$ref", "title", "description", "examples", "default",
  "type", "properties", "required", "additionalProperties", "items",
  "enum", "minimum", "maximum", "exclusiveMinimum", "minLength", "maxLength", "pattern",
]);

const unknown = new Set();
(function survey(node) {
  if (Array.isArray(node)) return node.forEach(survey);
  if (node === null || typeof node !== "object") return;
  for (const [key, value] of Object.entries(node)) {
    // Only keys in schema position, not names inside `properties` or `$defs`.
    if (!KNOWN.has(key) && node.properties !== value && node.$defs !== value) {
      if (node === schema.properties || node === schema.$defs) continue;
      unknown.add(key);
    }
  }
  for (const [key, value] of Object.entries(node)) {
    if (key === "properties" || key === "$defs") {
      for (const inner of Object.values(value)) survey(inner);
    } else if (key !== "enum" && key !== "required") {
      survey(value);
    }
  }
})(schema);

function resolve(node) {
  if (node && node.$ref) {
    const path = node.$ref.replace(/^#\//, "").split("/");
    let at = schema;
    for (const step of path) at = at[step];
    return at;
  }
  return node;
}

const TYPE_OF = (value) => {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (Number.isInteger(value)) return "integer";
  return typeof value;
};

function check(value, node, path, problems) {
  node = resolve(node);
  if (!node) return;

  if (node.type) {
    const actual = TYPE_OF(value);
    const wanted = Array.isArray(node.type) ? node.type : [node.type];
    const ok = wanted.some((t) =>
      t === actual || (t === "number" && actual === "integer"));
    if (!ok) {
      problems.push(`${path}: expected ${wanted.join(" or ")}, found ${actual}`);
      return;  // every other rule below assumes the type held
    }
  }
  if (node.enum && !node.enum.includes(value)) {
    problems.push(`${path}: ${JSON.stringify(value)} is not one of ${node.enum.join(", ")}`);
  }
  if (typeof value === "string") {
    if (node.minLength !== undefined && value.length < node.minLength) {
      problems.push(`${path}: shorter than ${node.minLength}`);
    }
    if (node.maxLength !== undefined && value.length > node.maxLength) {
      problems.push(`${path}: longer than ${node.maxLength}`);
    }
    if (node.pattern && !new RegExp(node.pattern).test(value)) {
      problems.push(`${path}: ${JSON.stringify(value)} does not match ${node.pattern}`);
    }
  }
  if (typeof value === "number") {
    if (node.minimum !== undefined && value < node.minimum) {
      problems.push(`${path}: ${value} is below ${node.minimum}`);
    }
    if (node.maximum !== undefined && value > node.maximum) {
      problems.push(`${path}: ${value} is above ${node.maximum}`);
    }
    if (node.exclusiveMinimum !== undefined && value <= node.exclusiveMinimum) {
      problems.push(`${path}: ${value} is not above ${node.exclusiveMinimum}`);
    }
  }
  if (Array.isArray(value) && node.items) {
    value.forEach((entry, i) => check(entry, node.items, `${path}[${i}]`, problems));
  }
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    for (const name of node.required ?? []) {
      if (!(name in value)) problems.push(`${path}: missing required "${name}"`);
    }
    for (const [key, entry] of Object.entries(value)) {
      const rule = node.properties?.[key];
      if (rule) {
        check(entry, rule, `${path}.${key}`, problems);
      } else if (node.additionalProperties === false) {
        problems.push(`${path}: "${key}" is not a field this schema allows`);
      } else if (typeof node.additionalProperties === "object") {
        check(entry, node.additionalProperties, `${path}.${key}`, problems);
      }
    }
  }
}

function patches(dir, found = []) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) patches(path, found);
    else if (entry.endsWith(".json")) found.push(path);
  }
  return found;
}

const files = [
  ...patches(join(root, "examples", "patches")),
  ...patches(join(root, "tests", "sfxr", "patches")),
];

let bad = 0;
for (const file of files) {
  const problems = [];
  check(JSON.parse(readFileSync(file, "utf8")), schema, "patch", problems);
  if (problems.length > 0) {
    bad += 1;
    console.error(`${relative(root, file)}:`);
    for (const problem of problems.slice(0, 6)) console.error(`  ${problem}`);
    if (problems.length > 6) console.error(`  ... and ${problems.length - 6} more`);
  }
}

if (unknown.size > 0) {
  console.error(`the schema uses keywords this checker does not implement: ` +
    `${[...unknown].join(", ")}`);
  console.error("Implement them or the check is quietly narrower than it looks.");
  process.exit(1);
}
if (bad > 0) {
  console.error(`${bad} of ${files.length} patches do not match schema/patch.schema.json.`);
  process.exit(1);
}
console.log(`${files.length} patches match schema/patch.schema.json.`);
