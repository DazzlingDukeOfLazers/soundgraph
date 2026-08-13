# CLAUDE.md — SoundGraph

## Mission

Build the smallest portable implementation that proves the SoundGraph abstraction.

The canonical artifact is a portable, versioned sound graph.

Early targets:

```text
native
browser/WASM
web editor
Godot editor
ESP32-S3
```

Later:
- ESP32-P4
- desktop packages
- AU/VST3
- Axoloti/Ksoloti experiments

## Autonomy

Continue through ordinary, locally reversible implementation work without asking for confirmation.

Do not stop after every successful step with "Would you like me to continue?"

Stop only when:
- architecture choices have materially different long-term consequences
- requirements conflict
- operation is destructive/difficult to reverse
- credentials/secrets are needed
- external publishing/purchasing is needed
- licensing/dependency choice has major consequences
- testing reveals a product/design decision rather than an implementation defect

For ordinary problems:
1. reproduce
2. investigate
3. hypothesize
4. test
5. fix/document
6. regression test
7. continue

## Durable context

Maintain:

```text
docs/current-phase.md
docs/decisions.md
docs/known-issues.md
docs/test-matrix.md
```

At session start:
1. inspect git status
2. read current phase
3. read recent decisions
4. inspect relevant tests
5. continue active milestone

## Architecture rules

- Patch format is canonical.
- Always include `schema_version`.
- Preserve stable node IDs.
- Validate before execution.
- DSP core does not depend on Godot.
- DSP core does not depend on browser JavaScript.
- No filesystem/network/allocation in steady-state realtime processing.
- Target-specific code stays at edges.
- Browser DSP should prefer WASM in AudioWorklet.
- Godot is a UI/education frontend, not graph semantics.
- Board profile and processor target are separate.
- Do not design custom hardware before dev boards prove the architecture.

## Test discipline

Every meaningful DSP node should have, where practical:
- unit test
- serialization test
- golden vector/audio test
- target compatibility metadata

Compare native/WASM/embedded outputs within declared tolerances.

### The gate

`tools/pre-push.sh` builds, runs ctest, and runs the three Godot suites. Enable it once
per clone — hooks are not cloned, only the script is:

```sh
git config core.hooksPath tools/hooks
git config soundgraph.godot /path/to/godot_console   # optional; the suites skip without it
```

It runs everything rather than a chosen few. Two of those ctest cases —
`node_demos_match_the_registry` and `game_sounds_match_the_corpus` — went red and stayed
red across several commits without anybody noticing, which is what prompted this. They are
the checks that catch a *generated* file edited by hand instead of the generator that
writes it: a mistake that looks fixed until something regenerates.

`git push --no-verify` skips it. That is for a push that cannot break anything, not for
getting past a red suite.

## Worktrees

Parallel worktrees are encouraged after interfaces stabilize.

Good split:

```text
A: DSP core + tests
B: WASM/web
C: Godot UI
```

Do not independently redesign patch schema, node API, signal typing, or target model across worktrees.

## Decision log

Record meaningful decisions in `docs/decisions.md`:

```text
## YYYY-MM-DD — Title

Decision:
Reason:
Alternatives:
Consequences:
```

## Knobcon

Target: September 11, 2026  
Feature freeze: September 4, 2026

Critical path:

```text
patch schema
DSP core
scheduler
tests
native sound
WASM/browser sound
minimal web editor
Godot editor
one ESP32-S3 target
reliable demo
```

Not critical:
- AU/VST3
- P4
- custom PCB
- Pure Data compatibility
- Axoloti compatibility
- multiple boards
- cloud/marketplace

## UX rules

Prefer:
- readable nodes
- human-readable names
- task-oriented search
- typed ports
- compatible-port highlighting
- live signal inspection
- spatial/actionable errors
- progressive disclosure
- good defaults

Do not reproduce tiny/cryptic conventions just because they are traditional.

## Scope guardrail

Do not turn SoundGraph into a general-purpose visual programming environment yet.

Defer:
- arbitrary Python
- HTTP nodes
- database nodes
- shell nodes
- general scripting
- cloud workflow nodes

## Core success condition

> One graph behaves consistently in multiple radically different execution environments.

When uncertain between building infrastructure and making the first graph audibly work, prefer making the first graph audibly work.
