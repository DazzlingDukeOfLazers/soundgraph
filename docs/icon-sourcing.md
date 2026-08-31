# Sourcing an Icon

When to go and look at what other people have drawn, how to do it without spending money,
and what to write down afterwards.

Separate from `docs/node-glyph-grammar.md` on purpose. The grammar is how a mark is
constructed; this is how evidence is gathered about what a mark should mean. They answer
different questions and they should be able to change independently.

## The rule

> **Search establishes semantic consensus. SoundGraph owns the final glyph geometry.**

Which is to say: go and find out which metaphor ordinary people recognise, then draw it
here, in this grammar, at this weight, on this grid. The corpus is evidence about meaning,
not a supplier of artwork.

That keeps the set coherent — a mark borrowed from one collection and a mark borrowed from
another are two visual languages in one header — and it keeps the licensing simple, which
matters more than it sounds like it does. A drawn mark owes nobody anything. A sourced one
brings an attribution obligation into the application, permanently, for one icon.

### When not to search

Most of the time. For canonical technical symbols the consensus is already known and
searching for it is a way of asking a question you can answer:

```
filter response      known — flat, a knee, away down the stop end
ADSR                 known — attack, decay, sustain, release
waveform             known — sine, square, saw, noise
pulse train          known — evenly spaced uprights
split and merge      known — the graph the reader is already looking at
```

Draw these. The step 9 search confirmed all three of its concepts and changed none of
them, which is the expected outcome for a symbol that already has a convention: useful as
evidence, not as direction.

### When to search

When the metaphor is genuinely ambiguous and the disagreement is about what a normal
person would recognise, not about what is correct. A compressor, a chorus, a quantiser —
things whose behaviour is clear and whose picture is not. That is the case worth spending
a search on, and the useful output is not an icon, it is the shape of the consensus and
whether one exists at all.

## The workflow

The client is `TheMutantFactory/noun-project-utils`, a standard-library Python CLI for
Noun Project API v2. Credentials resolve from `NOUN_KEY`/`NOUN_SECRET`, then
`~/.config/noun/credentials.cfg`, then the Dot-Gobbler game's own Godot store, so on a
machine where that game is configured there is no setup.

**Browsing is free. Only downloading costs.**

```
./noun.py usage                      quota                            free
./noun.py search "low pass filter"   ids, terms, licences             free
./noun.py search ... --json          creator, collection, tags,       free
                                     attribution, thumbnail_url
./noun.py get 4799932                the artwork itself            METERED
./noun.py get 4799932 -n             what it would cost               free
```

The whole of the step 9 search — four concepts, a dozen queries, twenty-six candidates
looked at — moved the metered counter by zero. Search results carry `thumbnail_url` on
the static CDN (`https://static.thenounproject.com/png/{id}-200.png`), which any HTTP
client can fetch without touching the API at all. Pull the thumbnails, tile them into a
contact sheet, and look. That is the whole browsing half of the work and it is free.

**Fetch the artwork only when the intention is to use it.** A metered download is not a
way of looking more closely; the thumbnail is enough to judge a mark that will be drawn at
twenty-four pixels.

## What to keep, if a glyph is ever genuinely sourced

`TheMutantFactory/get-in-loser` is the layout, and it is a good one:

```
the downloaded original      kept, so derived files can be rebuilt rather than
                             being mystery binaries
a licence record             id, term, creator, collection, tags, licence, url,
                             what it is used for, source file, derived files
a generator                  rebuilds every derived image, byte for byte
the attribution, in prose    with the modifications named
```

All four separate from the normalised in-product mark. And the thing it names that
SoundGraph does not have: **CC BY wants visible attribution**, so a sourced icon means the
application needs somewhere to show it, and that somewhere is Help.

**Do not build that surface for reference thumbnails.** Nothing is owed for looking. An
attribution panel that credits artwork the program does not contain is worse than no
panel, because it makes a licensing claim that is not true.

## Ambiguous search vocabulary

Search terms that mean something else outside this domain, and what to use instead. Worth
keeping beyond icon work — the same words are the ones a user types into the node browser.

**`gain`** is heavily financial. A search returns arrows, bar charts and dollar coins, and
none of the first twelve results had anything to do with audio. Prefer:

```
amplifier            the schematic symbol, and the strongest result by far
signal gain
audio gain
amplitude
level
```

Nothing else has been measured. This section is a list of findings, not a vocabulary
design, and it grows one entry at a time when a search comes back wrong.

**The node browser's own search is not changed by this.** These are notes for whoever
looks at it next; `BrowserItem.search_terms` is frozen where step 3 left it.
