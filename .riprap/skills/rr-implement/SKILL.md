---
name: rr-implement
description: >-
  Helps the user implement a feature.
  TRIGGER when: the user asks to add, build, create, make, or implement something (new feature, new
  system, new command, new API, new behaviour); the user asks to implement functionality described
  in a requirements file.
  SKIP: the user is asking to fix a bug in existing code; the user is asking to refactor or rename
  existing code without changing behaviour; the user is explicitly asking only to plan or design
  (those go to rr-plan instead).
---

Check for a markdown file in the `rqm` directory that corresponds to the requested feature. If no such file is found, instead execute the /rr-plan skill.

Ensure that the implemented code satisfies all Gherkin scenarios in the requirements file.

Create at least one test corresponding to every Gherkin scenario.

## Requirements Traceability

The project uses a stable ID system (`rq-XXXXXXXX`) to link source code to requirements. Follow
these steps to keep traceability accurate throughout implementation.

### Before Modifying Existing Code

When you encounter an `rq-XXXXXXXX` token in a comment in any source file you are about to change,
look up the requirement it refers to before making changes:

```
.riprap/skills/rr-plan/rqm.sh show rq-XXXXXXXX
```

This prints the type, file, title, and declaration of the requirement. Read the referenced
requirement in full so you understand what the code is implementing before proposing changes. If the
proposed change would alter behaviour covered by that requirement, re-read the requirements file to
confirm the change is still compliant.

### While Writing New Code

Every function, type, test, or significant block of logic that directly implements a specific
requirement entity (a section, API item, or Gherkin scenario) must carry a comment referencing that
entity's ID on the line immediately preceding (or on the same line as) the declaration. Use the
comment style appropriate to the language:

- Rust / C / C++ / JavaScript / TypeScript: `// rq-XXXXXXXX`
- Python / Shell: `# rq-XXXXXXXX`
- SQL: `-- rq-XXXXXXXX`


For a Gherkin scenario tagged `@rq-7c1e5d3b`, the corresponding test function should be annotated:

```rust
#[test] // rq-7c1e5d3b
fn download_basis_set_not_cached() { ... }
```

For an API function with ID `rq-9b4d2f1a`:

```rust
// rq-9b4d2f1a
pub fn fetch_basis(element: &str, basis_name: &str) -> Result<PathBuf, BseError> { ... }
```

A single source line may carry multiple IDs if it implements multiple requirement entities:

```rust
// rq-9b4d2f1a rq-3a7f1c2e
pub fn fetch_basis(...) { ... }
```


Do not fabricate IDs. Only reference IDs that are present in the requirements files under `rqm/`.

### After Finishing Implementation

Once all code and tests have been written, regenerate the registry so that the new source references
are recorded:

```
.riprap/skills/rr-plan/rqm.sh index
```

If `index` exits non-zero (e.g. due to duplicate IDs in the markdown), follow the instructions it
prints before proceeding.

## Project-Specific Extensions

Read `.riprap/skills/rr-implement/local.md` and follow any instructions it contains. Where those
instructions conflict with the instructions above, `local.md` takes precedence.
