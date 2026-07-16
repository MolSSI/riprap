---
name: gr-architecture
description: >-
  Establishes the high-level goals and architecture of the whole project, recorded in
  `rqm/ARCHITECTURE.md`. This is normally the FIRST skill run in a newly generated project, before
  any `/gr-plan` or `/gr-implement` work.
  TRIGGER when: the user asks to define, establish, set up, or revise the project's overall
  architecture, high-level goals, vision, scope, or major technical direction; the user is starting
  a brand-new project and asks where to begin; `rqm/ARCHITECTURE.md` is still an unfilled placeholder.
  SKIP: the user asks to plan or specify a single feature (use gr-plan instead); the user asks to
  implement or change code (use gr-implement instead).
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion, Write, Edit
---

Your only output is the file `rqm/ARCHITECTURE.md`. Do not plan individual features in detail, and
do not write or modify any source code. This skill captures the small number of decisions that have
broad leverage over the whole project — the ones that would be expensive to reverse and that shape
many future features. Everything finer-grained than that is deferred to `/gr-plan`.

## What This Document Is For

`rqm/ARCHITECTURE.md` is the high-level orientation for the project. A reader — human or agent —
should be able to read it and understand what the project is, what is in scope, and the major
technical commitments, without reading any code. It sits above the per-feature requirements files
that `/gr-plan` produces: those describe individual features in testable detail; this describes the
system they all live in.

Capture only what has architectural leverage. It is **not** important to nail down every detail here
(that is what `/gr-plan` is for). The goal is to glean the information that would tend to heavily
influence future decisions. When in doubt about whether something belongs here, ask: "would getting
this wrong force a broad, expensive rewrite later?" If yes, it belongs here; if it is a local
detail of one feature, leave it for `/gr-plan`.

## Seed Context

This project is named **Guardrails** and is written in **rust**. At creation it was
described as:

> Provides project scaffolding for AI-assisted development

Treat these as your starting point. Do not re-ask what the template already captured; build on it.

## Examine the Current State

Before asking anything, orient yourself:

- Read `rqm/ARCHITECTURE.md` if it exists. If its content is still the scaffolded placeholder (a
  block quote telling the agent to run this skill), treat this as a **first-time** run: you are
  defining the architecture from scratch and will replace the placeholder entirely.
- If `rqm/ARCHITECTURE.md` already contains real content, treat this as a **refinement** run: you
  are revising or extending an existing architecture, not starting over (see *Refining an Existing
  Architecture*).
- Read `CLAUDE.md` and skim any existing requirements files under `rqm/` and any existing source
  directories, so your questions account for decisions already made.

## The Areas to Establish

A complete `rqm/ARCHITECTURE.md` speaks to each of the following. Not every project needs every
subsection, but you should actively consider each one and only omit it when it genuinely does not
apply.

1. **Primary purpose** — what the software is fundamentally for, and its intended **scale and
   audience**. A small project for personal learning and a large production code used by a broad
   community lead to very different architectures; pin down which this is.
2. **Key in-scope features** — the capabilities the project commits to, *especially those that carry
   architectural weight*. A feature that dictates a data layout, an execution model, or a major
   dependency belongs here; a routine feature that fits comfortably within decisions already made
   does not.
3. **Extensibility** — how, and how much, the system is expected to be extended. Does it need a
   robust plugin system? Should users be able to define their own variants of core components, and
   if so by what mechanism? Getting the extension model wrong is one of the most expensive mistakes
   to correct later, so probe it deliberately.
4. **Architectural decisions** — the major technical commitments: language(s), key libraries and
   frameworks, execution target(s) (CPU, GPU via CUDA/OpenCL/Metal, distributed/MPI, single-node),
   data-layout and concurrency priorities, and any other cross-cutting choice that many features
   will depend on.
5. **Testing strategy** — how correctness is established at the whole-project level. In particular,
   whether a general end-to-end or conformance harness should exist that exercises a whole class of
   components against a standardized set of tests, rather than every feature bringing only its own
   bespoke tests.

## Ask Clarifying Questions

This is the core of the skill. Initial project descriptions are usually far broader than the user
realizes, and your job is to turn a broad ambition into a set of concrete, load-bearing decisions.
Use the `AskUserQuestion` tool, batching related questions into a single call. Keep going until each
of the areas above is either settled or explicitly deferred.

Probe at least these dimensions, adapting them to the project:

- **Scale and audience** — learning/personal exercise vs. production code for a broad community.
- **Execution targets** — CPU only; GPU (which API?); single-node vs. distributed/MPI.
- **Core capabilities that shape the architecture** — which in-scope features force structural
  decisions, and which are ordinary.
- **Extensibility model** — plugin system vs. fixed set; user-defined components and how they are
  registered and discovered.
- **Key libraries and dependencies** — what the project will lean on, and where it deliberately
  avoids a dependency (the project philosophy is to be hesitant about dependencies for small tasks).
- **Testing strategy** — whether standardized/conformance harnesses are wanted for whole classes of
  components.
- **Killer features / differentiators** — any specific capability the user wants that might warp the
  architecture around it.
- **Explicit non-goals** — what is deliberately out of scope. Recording this is as valuable as
  recording what is in scope.

**Worked example.** Suppose the user says "I want to build a molecular dynamics code." That is
extremely broad, and good questions would include: Is this a small project for learning the inner
workings of MD, or a large production code for the broader community? Should it run on CPUs, GPUs
with CUDA, GPUs with OpenCL, or several of these? Should it support multi-step integrators? Are ab
initio MD or QM/MM in scope? Will potentials come from ML models, traditional force fields, or both?
Are there specific killer features that would affect the overall architecture? How should end-to-end
testing be handled — for example, should a general harness cover all pair potentials with a
standardized set of tests? How important is support for user-defined potential forms, and what is
the process for adding one — does the code need a robust plugin system? Aim for this level and kind
of questioning, tailored to whatever the user is actually building.

## Current-State Framing

Write `rqm/ARCHITECTURE.md` as a flat, declarative description of the project's **current intended
design**, not as a history of how the design evolved. A reader who has never seen a prior version
should understand the intended architecture from the text alone. Avoid delta language ("we now
add…", "previously the code used…", "this changes X to Y"); prefer plain statements of what is true
("The engine runs on the GPU via CUDA", "Potentials are supplied through a plugin trait"). This
applies on refinement runs too: rewrite affected sections so they read as a from-scratch description
of the current intent, rather than appending change notes.

## Document Structure and Location

Write the document to `rqm/ARCHITECTURE.md`. Keep the top-level heading as `# Architecture` so the
`@rqm/ARCHITECTURE.md` reference in `.guardrails/CLAUDE.md` continues to resolve to a titled
document. A good default section layout:

```markdown
# Architecture

## Purpose
<what the project is for; its intended scale and audience>

## Scope and Key Features
<the capabilities the project commits to, emphasizing those with architectural weight>

### Non-Goals
<what is deliberately out of scope>

## Architectural Decisions
<language(s), execution target(s), key libraries, data layout, concurrency, and other
cross-cutting commitments>

## Extensibility
<extension points; plugin model; how users add their own variants of core components>

## Testing Strategy
<whole-project testing approach; any standardized or conformance harnesses>

## Open Questions
<decisions deliberately deferred, to revisit as the project matures>
```

Add, merge, or drop sections to fit the project — this layout is a starting point, not a rigid
schema. Keep the whole document high-level and readable; push anything that belongs in a single
feature's specification into a `/gr-plan` requirements file instead.

## Refining an Existing Architecture

When `rqm/ARCHITECTURE.md` already holds real content, default to **editing it in place**. Change
only the sections the user's request touches, and match the size of the edit to the size of the
change. Do not rewrite settled sections that the request does not concern, and do not clobber the
whole file to make a small revision. If a change to the architecture invalidates decisions recorded
in existing `/gr-plan` requirements files, point that out to the user rather than silently editing
those files — reconciling them is a separate `/gr-plan` task.

## Traceability

`rqm/ARCHITECTURE.md` is a high-level orientation document, not a requirements specification. Unlike
the feature files produced by `/gr-plan`, it is **exempt from the `rq-XXXXXXXX` traceability ID
system**: do not add `rq-` annotations to its headings, and do not run `rqm.sh stamp` or `rqm.sh
index` as part of this skill.

## Project-Specific Extensions

Read `.guardrails/skills/gr-architecture/local.md` and follow any instructions it contains. Where those
instructions conflict with the instructions above, `local.md` takes precedence.
