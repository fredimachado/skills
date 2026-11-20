# unslop

Edits text so it stops sounding like a machine wrote it.

Skill file: [skills/unslop/SKILL.md](../skills/unslop/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Text written by AI has habits. Readers spot them in a sentence or two, and once they do,
they trust the rest less, even when it is correct. The habits also waste the reader's
time. A paragraph can sound impressive and say nothing you could act on.

`unslop` lists those habits and removes them. It also covers the opposite failure, which
is text so scrubbed that it has no voice left.

## How it works

1. **Scan** the text for the patterns in the list.
2. **Rewrite,** keeping the meaning and the intended tone.
3. **Add a voice.** Have an opinion, vary the rhythm of the sentences, be specific.
4. **Ask "what makes this obviously AI generated?"** and fix what is left.

The patterns fall into groups. A few from each:

- **Content.** Inflated importance ("a pivotal moment"), claims with no source ("experts
  believe").
- **Language.** Words such as "delve", "crucial" and "showcase". "Not just X, but Y".
  Ideas forced into groups of three.
- **Style.** Em dashes, colons used to join sentences, bold on every other phrase,
  headings in title case, decorative emoji.
- **Chatbot leftovers.** "I hope this helps!", "Great question!".
- **Filler.** "In order to" where "to" will do, hedges stacked on hedges.
- **Jargon.** Abstract nouns such as "substrate" or "paradigm" where a plain word exists.
- **Plain speech.** Say what a thing does, not how it feels. Use the active voice. Cut
  the adverb or pick a stronger verb.

Its sharpest test is whether a sentence could appear unchanged in another project's
documentation. If it could, it says nothing about this one, and the skill cuts it.

## How it connects

It calls no other skill, and no skill calls it. Its description says it must always
apply, so once installed it shapes everything an agent writes. That includes text other
skills produce, such as a pull request description from [file-pr](file-pr.md).

The guides in this folder were written to its rules.

## How to ask for it

"Unslop this README", or "this reads like AI wrote it, fix it".
