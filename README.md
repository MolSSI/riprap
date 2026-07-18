# Guardrails

**Important:** This repository and the ideas expressed within represent an early effort to identify best practices for AI-assisted development, and do not yet reflect official MolSSI recommendations.

## Getting Started

### Prerequisites

Install Podman, following the official podman installation [instructions](https://podman.io/docs/installation).

Install [Copier](https://copier.readthedocs.io/en/stable/#installation).

You'll also need access to either Claude Code or Codex.

### Creating a new repository

This repository is a Copier template.
To create a new project, you can do:

```bash
copier copy gh:MolSSI/guardrails my-new-project
```

To pull the latest Guardrails updates into your project, you can do:

```bash
copier update
```

### Template questions

When you run `copier copy`, Copier asks the following questions.
Every project is asked:

| Question | Description |
|---|---|
| `project_name` | Human-readable name of the project (e.g. "My Project") |
| `project_slug` | Short identifier used in image names, directory names, etc. Defaults to a lowercased, hyphenated form of `project_name`. |
| `project_description` | One-sentence description of the project |
| `language` | Primary programming language: `rust` (default) or `python` |
| `author_name` / `author_email` | Author information, used in packaging metadata and generated files |
| `open_source_license` | `MIT` (default), `BSD-3-Clause`, `LGPL-3.0-or-later`, or `Not Open Source`. Any choice other than `Not Open Source` generates a corresponding `LICENSE` file. |
| `copyright_year` | Year used in the `LICENSE` file. Only asked when a license is selected. |

Projects that select `rust` are additionally asked:

| Question | Description |
|---|---|
| `include_rust_skeleton` | Whether to create skeletal Rust crate files: `Cargo.toml`, `src/lib.rs`, a `tests/` directory, and a CI workflow (`.github/workflows/CI.yaml`) that checks formatting, runs clippy, and runs the test suite with coverage. Defaults to yes; answer no when adding Guardrails to an existing Rust project. |

Projects that select `python` are additionally asked:

| Question | Description |
|---|---|
| `package_name` | Python import name of the package (the directory under `src/`). Defaults to `project_slug` with hyphens replaced by underscores. |
| `include_python_skeleton` | Whether to create skeletal Python package files: `pyproject.toml`, the `src/` package, a `tests/` directory, and a CI workflow (`.github/workflows/CI.yaml`). Defaults to yes; answer no when adding Guardrails to an existing Python package. |
| `first_module_name` | Name of the first module created inside the package. Defaults to `package_name`. Only asked when the skeleton is included. |
| `include_docs` | Whether to create a Sphinx documentation skeleton in `docs/` with a ReadTheDocs configuration (`.readthedocs.yaml`). Defaults to yes. |
| `dependency_source` | Where project dependencies come from: `Prefer conda-forge with pip fallback` (default), `Prefer default anaconda channel with pip fallback`, or `Dependencies from pip only (no conda)`. Conda-based choices generate a `devtools/conda-envs/test_env.yaml` environment and configure the CI workflow and documentation builds to use conda; the pip-only choice uses `pip` and `venv` throughout. |

The Python scaffolding produced by these questions is adapted from the [MolSSI CMS Cookiecutter](https://github.com/MolSSI/cookiecutter-cms); the Rust scaffolding follows the same structure.
Both languages also receive GitHub community files (`.github/CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `CODE_OF_CONDUCT.md`) and, when a skeleton is generated, a Codecov configuration (`.codecov.yml`).
All of the generated files listed above are *seeds*: they are created once when the project is generated, are yours to edit freely, and are never touched by `copier update`.
The exception is `.github/workflows/codeql.yaml` (generated for both languages), which is owned by the template and receives improvements through `copier update`; prefer leaving it unedited.

### Developing with Guardrails

#### 1. Launch a development container

All development **must** take place within a Podman container.
The template includes hooks that prevent Claude Code and Codex from answering prompts unless you are running in a containerized environment.
To launch a development environment, run `bash gr.sh` on Linux/Mac, or `gr.bat` on Windows.
This builds the container and drops you into an interactive bash shell in `/work`.
Run `claude` from the shell to start Claude Code, or `codex` to start Codex.
Before using Codex for the first time in a project, authenticate from inside the container with
`codex login --device-auth` and complete the login in your browser (you may run the browser outside
the container). Device authentication because the container operates within an isolated network
namespace - for the purpose of logging in, your container counts as a separate device. This is
only necessary the first time you use the container for this project.
On the first Codex run, use `/hooks` to review and trust the repository's container-check hook;
Codex deliberately does not run a new project-local hook until you approve its exact definition.

The container is built in two layers: a base image defined in `.guardrails/podman/Containerfile` provides the standard environment (Claude Code, Codex, the language toolchain, and supporting utilities), and a user-owned `Containerfile` at the project root layers on top of it.
Edit the root `Containerfile` to install additional system packages or tools your project needs; leave the base image alone so that `copier update` can keep it in sync with upstream changes.

#### Updating Claude Code and Codex

The agents update themselves automatically, at most once a week, with no action from you.

The agents will not auto-update *within* the container (such changes would only last as long as
the container itself, and would need to be repeated every time you launch a new container).
Instead, the launcher reinstalls them when the calendar week changes, so the agents are never more
than a week behind their current releases. One launch a week therefore takes a few minutes longer
while the agent layers rebuild; every other launch reuses the cache and contacts the network not
at all. If a rebuild fails — no network, or a broken upstream release — the launcher says so and
carries on with the image you already have, so a refresh can never block your work.

##### Pinning a release

If a new agent release turns out to be a bad one, you can pin your way out of it without waiting
for an upstream fix. Create `.guardrails/agent-pin.env`:

```
CLAUDE_VERSION=2.1.205
CODEX_VERSION=0.144.6
```

Pinned agents are held at exactly those releases; any agent you leave out keeps tracking its
current release. Only exact `x.y.z` versions are accepted; values such as `latest` will error.
Delete the file to return to the weekly schedule described above.

#### 2. Create an initial file structure

The template seeds a skeletal, buildable project for you (unless you answered no to `include_rust_skeleton` / `include_python_skeleton`); follow the "Initializing the project" instructions in your generated project's README to set up an environment and check that the sample tests pass.
If you opted out of the skeleton, initialize the project manually — e.g. `cargo init` for Rust, or a virtual environment plus your existing packaging setup for Python.

#### 3. Define the project architecture

Before writing requirements for individual features, establish the project's high-level goals and architecture.
The template includes a `gr-architecture` skill for this, and running it is normally the first thing you do in a new project. In Claude Code, use:

```
/gr-architecture I want to build a molecular dynamics code.
```

In Codex, use:

```
$gr-architecture I want to build a molecular dynamics code.
```

The agent will ask a series of questions to turn a broad ambition into concrete, load-bearing decisions — the intended scale and audience, execution targets (CPU, GPU, distributed), which features carry architectural weight, how the system should be extended (for example, whether it needs a plugin system for user-defined components), the key libraries, and how whole-project testing should be handled.
It records the results in `rqm/ARCHITECTURE.md`, which the agent's project guidance references so that every later planning and implementation step shares the same architectural context.

The goal is not to specify every detail — that is the job of the per-feature requirements files below — but to capture the decisions that would be expensive to reverse later.
You can re-run the `gr-architecture` skill at any time to refine or extend the document as the project matures.

#### 4. Generate a requirements document

Before you begin generating code through the LLM, you **must** generate one or more requirements documents.
These are stored in markdown files in an `rqm` directory.
You should have a separate requirements document for each feature.

Included in this template is a skill to help you generate requirements documents, which is automatically invoked when appropriate.
For example, you can say:

```
I want to add a parser to my code that parses XYZ molecular structure files. Help me plan this feature, and place the requirements document in rqm/parser.md.
```

You can also invoke the skill explicitly in Claude Code:

```
/gr-plan I want to add a parser to my code that parses XYZ molecular structure files. Help me plan this feature, and place the requirements document in rqm/parser.md.
```

In Codex, use:

```
$gr-plan I want to add a parser to my code that parses XYZ molecular structure files. Help me plan this feature, and place the requirements document in rqm/parser.md.
```

The agent will then ask you numerous questions to clarify your detailed requirements, and will write them to a corresponding markdown file in the `rqm` directory.
Examine this file carefully, including the Gherkin scenarios - these will later be used to generate unit tests for your code.
Correct any issues with the file either manually or by asking the agent to make adjustments to the file.

For somewhat more complex features, it may prove useful to manually fill out a small portion of a requirements document, and then ask the agent to refine it.
For example, you might write a file in `rqm/basis/bse.md` with the following contents:

```
# Feature: Pull Missing Basis Set from Basis Set Exchange

There will be points when this code will need access to a Gaussian basis set for the purpose of electronic structure calculations.
Basis set files should be stored in a directory called `data/basis`.
If a required basis set is not available in this directory, it should be downloaded from the Basis Set Exchange (BSE), using the BSE API.
The BSE website is https://www.basissetexchange.org/.
If the `data/basis` directory does not exist, it should be created.

This feature implements a function that is given an atom type and the name of a basis set, and downloads the required file from the BSE if it is not already present.
```

Then, you can prompt:

```
Help me flesh out the requirements file in rqm/basis/bse.md
```

The agent will then automatically use the `gr-plan` skill.



#### 5. Implement the feature

You may now ask the agent to implement the feature, which will automatically invoke the `gr-implement` skill:

```
Implement the feature in rqm/requirements.md
```

#### 6. Iteratively refine the requirements and code

Examine and test the code the agent generates carefully.
If there are any problems, **modify the requirements file before changing the code**.
For example, you might prompt:

```
I want my parser to be able to support trajectory files that contain many snapshots. Help me modify the requirements file in rqm/parser.md accordingly. These trajectory files may be too big to load into memory all at once, so suggest options for how to handle this problem.
```

After making any changes to a requirements file, ask the agent to update the code:

```
I have made changes to rqm/parser.md to support trajectory files.  Update the implementation of the parser to conform to the latest version of the requirements file.
```

Repeat the above process for implementing additional features.


#### General points

It is fine for features to reference other features, and you may use subdirectories in `rqm` to better organize your requirements files.
As you develop, the documents in `rqm` should form a complete and coherent description of all the intended functionality of your code.
If you were to delete everything in `src`, it should be possible to reliably reproduce the functionality of your code by prompting the LLM to produce these features.
You should treat these requirements documents as your true work product - they are the most fundamental expression of the proper functioning of the project, not your source code or your tests.
In this approach, it may be helpful to view the development process as natural-language programming with an LLM translator, rather than LLM-generation of code.


### Quizzes

It is important that you understand the functionality of your code.
To help with this, the template includes a `gr-quiz` skill. Invoke it as `/gr-quiz` in Claude Code
or `$gr-quiz` in Codex.
If you prompt the LLM with this skill, it will ask you a question about the implementation details of your code.
Using this skill periodically is a great way to ensure that you aren't creating code you don't understand.


### Customizing skills

The authoritative, agent-neutral skill implementations live under `.guardrails/skills/`. Claude
discovers adapters for them under `.claude/skills/`, while Codex discovers adapters under
`.agents/skills/`. Each canonical skill directory contains a `local.md` file that belongs to your
project.
Guardrails creates it when your project is generated and never touches it again, so anything you write there survives `copier update`.
Use it to extend or override a skill with project-specific conventions—for example, pointing
`gr-plan` at a project-specific exemplar requirements file, or requiring `gr-implement` to run a
particular linter before finishing.
Where `local.md` conflicts with a skill's built-in instructions, `local.md` wins.
Avoid editing the `SKILL.md` files themselves; those are owned by the template, and local edits to them may produce merge conflicts when you run `copier update`.


## Key Rules of AI-Assisted Programming

### 1. Only ever use agentic AI inside of a rootless container

LLM's are intrinsically vulnerable to prompt injection and data poisoning, allowing even relatively unsophisticated attackers to alter the behavior of the LLM.
Malicious actors can easily hijack an LLM to send them a user's personal information (including ssh keys) or to instruct an LLM agent engage in destructive actions.
*There are no reliable ways of preventing LLMs from falling for these types of attacks.*
If you've used LLM agents before, you've no doubt noticed that they will often ask for permission before executing commands.
Don't let this lull you into a false sense of security - there are many ways around this permission structure.
If you run an LLM agent, you should *assume* that at some point it will take hostile actions.

One of the most important things you can do to protect yourself is to restrict any LLM agents to an isolated container environment that does not have sudo access.
Note that although Docker is currently the most popular containerization option, Docker containers have root access by default and are therefore not a good solution to the LLM security problem.
Instead, The MolSSI recommends using Podman.
Podman containers do not have root access by default, making them a generally better option when security is a concern.
To help you avoid accidentally exposing your entire system to hackers, generated repositories include hooks that prevent Claude Code and Codex from answering prompts unless they are run in a container.

Note that containerization is merely a first step in protecting yourself when using LLM agents.
Even when working in a container, you should treat the agent with considerable skepticism.
Among other things, this means that you must:
- Never give it any information you wouldn't give to a stranger.
- Never expose your private ssh keys or other personal information in your LLM container.
- Never give an LLM write access to your remote repository, and do not include GitHub credentials in your LLM container.
- Never push LLM-generated code until you are convinced that it hasn't introduced any exploits into your repository, and only push from outside of the container.

### 2. Switch to a development workflow that is customized for use with agentic AI.

Development with assistance from agentic AI represents a major paradigm shift that necessitates fundamental changes in processes and attitudes.
In particular, you will need to adopt a workflow that utilizes your AI agents in an intelligent way.
When first getting started, many users naturally fall into a "vibe-coding" workflow that looks like this:
1. Ask the AI to write some code.
2. Try running the code, and notice that something isn't quite working correctly.
3. Ask the AI to fix the issue.
4. Repeat steps 1-3.

There are many problems with this approach.
When you use a simple, one sentence prompt to ask an LLM to implement a complex and nuanced feature, it is almost guaranteed that you won't get what you want.
The LLM will naturally tend to write the simplest possible code that technically does what you asked for, while assuming happy paths (that is, situations in which everything else is working correctly) and ignoring possible edge cases.
For example, if you say "Write me a parser for XYZ molecular input files", the response from the LLM will likely make many assumptions about the formatting and contents of the XYZ files in question.
In a proper, maintainable implementation that is suitable for distribution, you would need to consider many nuances, including the following:
- What if the file doesn't exist?
- What if the file has unexpected blank lines?
- What if a line is missing expected columns?
- What if a line has extra columns that were not expected?
- What if columns in a line are tab-separated instead of space-separated?
- What if the number of atoms listed in the header does not match the number of atomic coordinates listed in the rest of the file?
- What if some of the atom types don't correspond to real elements?
- What if the file is a trajectory file that contains many frames?
- What should be done with the comment line in the header?

If you're taking the cavalier vibe-coding approach, you aren't even considering these nuances, let alone expressing them to the LLM.
It doesn't matter how good your LLM model is, or how good they become in the future: if you don't express what you want in clear and complete terms, you aren't going to get what you want.
Most of the real work of programming is consumed by dealing with all of the obnoxious edge cases that an untrained mind wouldn't even notice.

There are many workflows that can improve the utilization of AI agents.
As a baseline for getting started, we recommend the following workflow:
1. Create a requirements file for a feature.
2. Generate code to fulfill the requirements file.
3. If something about the new code is incorrect or insufficient, modify the requirements file to increase clarity or completeness.
4. Repeat 2-3 until the feature is satisfactory.

### 3. Your project's requirements files are the only source of truth.

This is another big paradigm shift.
Never write code that isn't directly necessitated by a requirements file.
First change the requirements file, then write the code (either manually or with LLM assistance).
The requirements files must form a complete description of the project that is sufficient to reproduce the behavior of the code from scratch, including full handling of edge cases and unhappy paths.
If the source code doesn't agree with the requirements, the code is wrong.
In practice, this means that as a single-contributor developer, you must follow the sorts of formal design processes normally associated with management of a human development team.
The primary difference is that an LLM is doing the grunt work.

### 4. Take full advantage of modern compilers, linters, etc.

One of the primary disadvantages of working with lower-level languages is that the up-front cost of writing an initial solution is higher.
With an LLM doing much of the work, this disadvantage is substantially mitigated; meanwhile, the benefits of having compile-time validation of the LLM agent's work is massive.
When working with a compiled code, LLM agents can automatically attempt to compile the code, and then iteratively make any necessary corrections until all compiler errors and warnings are resolved.
Many of these same errors would not be caught until runtime when using an interpreted language such as Python or Ruby, and runtime errors are much trickier for both humans and LLMs to notice and debug.

Having said this, many low-level compiled languages, including C and C++, introduce another major headache in the form of memory bugs.
These sorts of bugs are easy for both humans and LLMs to accidentally introduce, while being notoriously difficult to identify or debug.
This makes memory-safe languages, such as Rust, especially appealing for the purpose of LLM-assisted work.
