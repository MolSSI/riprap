# Feature: Requirements Traceability ID System

This feature defines a scheme for assigning stable, opaque identifiers to requirements entities
(files, sections, API items, and Gherkin scenarios) and provides a standalone bash script,
`rqm.sh`, located at `.claude/skills/plan-feature/rqm.sh`, that stamps, indexes, and validates
those identifiers across the codebase. The goal is to make it straightforward to locate every
affected artefact when a requirement changes.

---

## ID Format and Assignment

### ID Format

Each identifier has the form `rq-XXXXXXXX`, where `XXXXXXXX` is exactly 8 lowercase hexadecimal
characters drawn uniformly at random. Examples: `rq-3a7f1c2e`, `rq-00deadbe`.

IDs are opaque and assigned once. They are never re-derived from content or names; editing or
renaming a requirement entity does not change its ID.

### Entities That Receive IDs

IDs are assigned to four entity types:

| Type       | Description                                                                 |
|------------|-----------------------------------------------------------------------------|
| `file`     | The requirements file as a whole (one ID per `.md` file under `rqm/`)       |
| `section`  | A `##` or `###` heading within a requirements file                           |
| `api-item` | A top-level bullet point in a Feature API section (function or named type); not sub-bullets |
| `scenario` | A `Scenario:` block inside a ` ```gherkin ` code fence                      |

Headings at `####` depth and below, and sub-bullet API items (e.g. individual error variants), do
not receive IDs.

### Inline Embedding in Markdown

IDs are stored directly in the markdown source using HTML comments (invisible when rendered) or
Gherkin tags:

- **File-level and section headings** — the ID is appended as an HTML comment at the end of the
  heading line:
  ```
  # Feature: Create Initial Atomic Orbital Guess <!-- rq-a3f2b1c7 -->
  ## Feature API <!-- rq-3a7f1c2e -->
  ### Functions <!-- rq-5d2b1a3f -->
  ```

- **API item bullet points** — the ID is appended as an HTML comment at the end of the line that
  opens the bullet:
  ```
  - `guess_hcore(s: &Mat<f64>, ...) -> Result<Mat<f64>, GuessError>` <!-- rq-9b4d2f1a -->
  - `GuessError` — error type returned by `guess_hcore` <!-- rq-8c3e1f2d -->
  ```
  An "API item" bullet is a top-level `- ` line (no leading spaces beyond the list marker) that
  appears inside a `## Feature API` or `### …` section within Feature API, and whose text contains
  at least one backtick-quoted identifier. Sub-bullets (additional indentation) are not API items.

- **Gherkin scenarios** — a Gherkin `@tag` annotation is inserted on its own line immediately
  before the `Scenario:` keyword, inside the code fence:
  ````
  ```gherkin
    @rq-7c1e5d3b
    Scenario: 2×2 system produces orthonormal MOs (S-metric)
  ```
  ````

### References in Source Files

An ID is "referenced" by a source file whenever any comment line contains the token
`rq-XXXXXXXX` (matching the regex `rq-[0-9a-f]{8}`). Multiple references to the same ID in the
same file at different lines are each recorded as a separate reference entry.

Source file types scanned for references: `.rs` and `.py` files under `src/` (and under `tests/`
when that directory exists), and `.md` files under `rqm/` (to capture cross-references between
requirements documents).

Example (Rust):
```rust
// rq-9b4d2f1a
pub fn guess_hcore(...) { ... }

#[test] // rq-7c1e5d3b
fn two_by_two_c_is_orthonormal() { ... }
```

Example (Python):
```python
# rq-9b4d2f1a
def guess_hcore(...): ...

# rq-7c1e5d3b
def test_two_by_two_c_is_orthonormal(): ...
```

---

## Registry

### File Location

`rqm/registry.json` at the project root (adjacent to `rqm/`).

### Schema

The registry is a JSON object mapping each `rq-XXXXXXXX` string to a record:

```json
{
  "rq-3a7f1c2e": {
    "type": "section",
    "file": "basis/guess",
    "title": "Feature API",
    "level": 2,
    "decl": "## Feature API",
    "refs": [
      { "kind": "code", "file": "src/guess.rs" }
    ]
  },
  "rq-9b4d2f1a": {
    "type": "api-item",
    "file": "basis/guess",
    "title": "guess_hcore",
    "decl": "- `guess_hcore(s: &Mat<f64>, t: &Mat<f64>, v: &Mat<f64>, n_alpha: usize, n_beta: usize) -> Result<Mat<f64>, GuessError>`",
    "refs": [
      { "kind": "code", "file": "src/guess.rs" }
    ]
  }
}
```

Fields per entry:

- `type` — one of `"file"`, `"section"`, `"api-item"`, `"scenario"`.
- `file` — path of the containing markdown file relative to `rqm/`, without the `.md` extension
  (e.g. `"basis/guess"`).
- `title` — human-readable label:
  - `file`: the text of the top-level `#` heading, excluding the leading `# `.
  - `section`: the full heading text, excluding leading `#` characters and trailing whitespace.
  - `api-item`: the first backtick-quoted name on the bullet line (e.g. `"guess_hcore"`).
  - `scenario`: the text following `Scenario:`, trimmed of leading and trailing whitespace.
- `level` — (`section` only) heading depth: `2` for `##`, `3` for `###`. Omitted for other types.
- `decl` — the full declaration line as it appeared in the markdown when the entry was last written
  by `index`, stripped of the trailing ID annotation (`<!-- rq-XXXXXXXX -->` or `@rq-XXXXXXXX`).
  Used by `stamp --fix-duplicates` to identify which copy of a duplicated entity is the original.
- `refs` — list of reference records. Each ref: `{ "kind": "code", "file": "<rel-path>" }`.
  `file` is relative to the project root. When the same ID appears more than once in a file,
  that file still appears as a single ref entry (deduplication by file path).

---

## Tool: rqm.sh

A standalone bash script located at `.claude/skills/plan-feature/rqm.sh`. Requires `bash` (≥ 4.0),
standard POSIX utilities (`grep`, `find`, `sed`, `awk`), and `jq` (for reading and writing the
JSON registry). A companion test suite lives at `.claude/skills/plan-feature/tests/test_rqm.sh`.

### Invocation

```
.claude/skills/plan-feature/rqm.sh <subcommand> [args]
```

Subcommands: `stamp`, `index`, `check`, `clean`.

### `stamp [--fix-duplicates] [files...]`

Reads the specified markdown files (or all `rqm/**/*.md` if no files are given). For each entity
that does not already have a valid `<!-- rq-XXXXXXXX -->` comment (or `@rq-XXXXXXXX` tag for
scenarios), assigns a fresh random ID. Writes each modified file in place. Never alters an existing
valid ID during a normal run.

ID uniqueness: each freshly generated ID is checked against all IDs already present in the file
being stamped and all IDs seen so far in the same stamp run; a collision triggers a regeneration
(retry up to 100 times before aborting with an error).

**`--fix-duplicates`**: Reads `rqm/registry.json` to obtain the stored `decl` for each known ID,
then scans the specified files (or all `rqm/**/*.md`) for duplicate IDs. For each duplicate, it
compares the live declaration of each copy against the stored `decl`:

- If exactly one copy's declaration matches the stored `decl`, that copy is treated as the
  original and its ID is left unchanged. The other copy has its ID annotation replaced with a
  freshly generated ID.
- If neither copy matches (both declarations have changed), or if both match (identical text),
  the duplicate is reported as unresolvable and left unchanged. The user must resolve it manually.

Prints a summary of every ID that was replaced and every unresolvable conflict. Exits non-zero if
any unresolvable conflicts remain.

### `index`

Re-scans all `rqm/**/*.md` files and all `.rs` and `.py` files under `src/` (and under `tests/`
when that directory exists) from scratch and writes a fresh `rqm/registry.json`, overwriting any
previous file. Never modifies markdown source files.

If any `rq-XXXXXXXX` ID appears in more than one entity in the scanned markdown files, `index`
reports each conflict, identifies which copy is likely the original (by comparing live declarations
against the `decl` stored in the existing registry, if present), and suggests running
`.claude/skills/plan-feature/rqm.sh stamp --fix-duplicates`. It exits non-zero and does not write the registry.

The index operation is otherwise idempotent.

### `check`

Reads `rqm/registry.json` and re-scans source files for `rq-[0-9a-f]{8}` tokens. Reports:

1. **Stale references** (error): an `rq-XXXXXXXX` token found in a source file that does not
   correspond to any ID in the registry. Exits with status 1 if any are found.
2. **Unreferenced requirements** (warning): an ID in the registry whose `refs` list is empty.
   Printed to stdout but does not affect the exit code.

### `clean`

Reads `rqm/registry.json` and removes stale data:

- Entries whose `file` no longer exists as `rqm/<file>.md`.
- Entries whose ID is no longer present in the corresponding markdown file.
- Individual `refs` entries whose `file` no longer exists, or whose `file` no longer contains the
  expected `rq-XXXXXXXX` token anywhere.

Prints a summary of every removed entry or ref. Writes the cleaned registry in place.

---

## Gherkin Scenarios

```gherkin
Feature: Requirements traceability ID system

  # --- stamp: headings ---

  Scenario: stamp adds an ID to a heading that has none
    Given a markdown file containing the line "## Feature API" with no HTML comment
    When rqm.sh stamp is called on that file
    Then the line becomes "## Feature API <!-- rq-XXXXXXXX -->"
    And the appended ID matches rq-[0-9a-f]{8}

  Scenario: stamp does not change a heading that already has a valid ID
    Given a markdown file containing "## Feature API <!-- rq-3a7f1c2e -->"
    When rqm.sh stamp is called on that file
    Then the line is unchanged

  Scenario: stamp adds an ID to the file-level # heading
    Given a markdown file whose first heading line has no HTML comment
    When rqm.sh stamp is called
    Then a "<!-- rq-XXXXXXXX -->" comment is appended to that heading line

  # --- stamp: API items ---

  Scenario: stamp adds an ID to a top-level API item bullet point
    Given a markdown file with a top-level bullet "- `guess_hcore(...)` → Result<...>" and no trailing comment
    And the bullet appears inside a "## Feature API" section
    When rqm.sh stamp is called
    Then the line becomes "- `guess_hcore(...)` → Result<...> <!-- rq-XXXXXXXX -->"

  Scenario: stamp does not add IDs to sub-bullet API items
    Given an indented sub-bullet "  - `SingularOverlap` — ..." inside a Feature API section
    When rqm.sh stamp is called
    Then the sub-bullet line is unchanged

  Scenario: stamp does not add IDs to bullet points outside a Feature API section
    Given a top-level bullet point that appears in a section other than Feature API
    When rqm.sh stamp is called
    Then that bullet point is unchanged

  # --- stamp: Gherkin scenarios ---

  Scenario: stamp adds a Gherkin tag to an un-tagged scenario
    Given a gherkin code block containing "  Scenario: 2x2 system" with no preceding @rq- tag
    When rqm.sh stamp is called
    Then a line "@rq-XXXXXXXX" is inserted immediately before the "  Scenario:" line
    And the tag matches @rq-[0-9a-f]{8}

  Scenario: stamp does not change a scenario that already has an rq- tag
    Given a gherkin scenario preceded by "@rq-7c1e5d3b" on the previous line
    When rqm.sh stamp is called
    Then the "@rq-7c1e5d3b" line is unchanged

  # --- stamp: ID uniqueness ---

  Scenario: stamp retries on collision within the same file
    Given that the random ID generator produces "rq-aaaaaaaa" twice in succession
    And "rq-aaaaaaaa" is already present in the file being stamped
    When rqm.sh stamp encounters the collision
    Then it generates a new ID for the second assignment
    And "rq-aaaaaaaa" appears exactly once in the resulting file

  # --- index ---

  Scenario: index builds registry from stamped markdown
    Given rqm/basis/guess.md has IDs on all entities
    When rqm.sh index is called
    Then rqm/registry.json is created
    And it contains one entry per ID found in the markdown files
    And each entry includes a decl field matching the declaration line stripped of its ID annotation
    And the registry is valid JSON

  Scenario: index records a source code reference
    Given rq-9b4d2f1a exists in rqm/basis/guess.md
    And src/guess.rs contains "// rq-9b4d2f1a"
    When rqm.sh index is called
    Then the registry entry for rq-9b4d2f1a contains a ref with file "src/guess.rs"

  Scenario: index deduplicates multiple occurrences of the same ID in one file
    Given two separate lines in src/guess.rs both contain "rq-9b4d2f1a"
    When rqm.sh index is called
    Then the registry entry for rq-9b4d2f1a has exactly one ref entry for "src/guess.rs"

  Scenario: index records cross-references between requirements files
    Given rqm/basis/initialization.md contains "rq-9b4d2f1a" in a comment
    When rqm.sh index is called
    Then the registry entry for rq-9b4d2f1a includes a ref with file "rqm/basis/initialization.md"

  Scenario: index is idempotent
    Given rqm.sh index has already been run and no files have changed
    When rqm.sh index is run again
    Then registry.json is byte-for-byte identical to its previous content

  Scenario: index aborts on duplicate and identifies the likely original via stored decl
    Given rq-3a7f1c2e is in the existing registry with decl "## Feature API"
    And rqm/basis/guess.md contains two headings annotated with rq-3a7f1c2e:
      one with text "## Feature API" and one with text "## New Section"
    When rqm.sh index is called
    Then an error is printed identifying both locations
    And the output marks "## Feature API" as the likely original
    And the output marks "## New Section" as the likely copy
    And the output suggests running stamp --fix-duplicates
    And the exit code is non-zero
    And registry.json is not written

  Scenario: index aborts on duplicate when neither declaration matches stored decl
    Given rq-3a7f1c2e is in the existing registry with decl "## Old Section"
    And rqm/basis/guess.md contains two headings annotated with rq-3a7f1c2e:
      one with text "## Section A" and one with text "## Section B"
    When rqm.sh index is called
    Then an error is printed reporting an unresolvable conflict for rq-3a7f1c2e
    And the output instructs the user to manually remove one of the duplicate annotations
    And the exit code is non-zero
    And registry.json is not written

  Scenario: index aborts on duplicate when no prior registry exists
    Given no rqm/registry.json exists
    And rq-3a7f1c2e appears in two different entities in rqm/basis/guess.md
    When rqm.sh index is called
    Then an error is printed identifying both locations
    And the output notes that no prior registry is available to identify the original
    And the output instructs the user to manually remove one of the duplicate annotations
    And the exit code is non-zero
    And registry.json is not written

  # --- stamp --fix-duplicates ---

  Scenario: stamp --fix-duplicates replaces the ID on the copy when original is identifiable
    Given rq-3a7f1c2e is in the registry with decl "## Feature API"
    And rqm/basis/guess.md contains two headings annotated rq-3a7f1c2e:
      "## Feature API <!-- rq-3a7f1c2e -->" and "## New Section <!-- rq-3a7f1c2e -->"
    When rqm.sh stamp --fix-duplicates is called
    Then "## Feature API <!-- rq-3a7f1c2e -->" is unchanged
    And "## New Section <!-- rq-3a7f1c2e -->" has its annotation replaced with a fresh ID
    And the replacement ID matches rq-[0-9a-f]{8} and differs from rq-3a7f1c2e
    And the result is printed to stdout
    And the exit code is 0

  Scenario: stamp --fix-duplicates reports and skips an unresolvable conflict
    Given rq-3a7f1c2e is in the registry with decl "## Old Section"
    And rqm/basis/guess.md contains two headings annotated rq-3a7f1c2e:
      "## Section A <!-- rq-3a7f1c2e -->" and "## Section B <!-- rq-3a7f1c2e -->"
    When rqm.sh stamp --fix-duplicates is called
    Then neither heading is modified
    And the conflict is reported as unresolvable with both locations printed
    And the exit code is non-zero

  Scenario: stamp --fix-duplicates reports and skips a duplicate with no prior registry
    Given no rqm/registry.json exists
    And rq-3a7f1c2e appears in two entities in rqm/basis/guess.md
    When rqm.sh stamp --fix-duplicates is called
    Then neither entity is modified
    And the conflict is reported as unresolvable
    And the exit code is non-zero

  # --- check ---

  Scenario: check passes when all source references are in the registry
    Given the registry contains rq-9b4d2f1a
    And src/guess.rs references rq-9b4d2f1a
    When rqm.sh check is called
    Then the output contains no errors
    And the exit code is 0

  Scenario: check reports a stale reference and exits non-zero
    Given src/guess.rs contains a reference to rq-deadbeef
    And rq-deadbeef is not in the registry
    When rqm.sh check is called
    Then the output reports a stale reference in src/guess.rs
    And the exit code is non-zero

  Scenario: check reports unreferenced requirements as a warning without failing
    Given rq-3a7f1c2e is in the registry with an empty refs list
    When rqm.sh check is called
    Then a warning is printed for rq-3a7f1c2e
    And the exit code is 0

  # --- clean ---

  Scenario: clean removes a registry entry for a deleted markdown file
    Given the registry contains rq-a3f2b1c7 with file "basis/old"
    And rqm/basis/old.md does not exist
    When rqm.sh clean is called
    Then rq-a3f2b1c7 is removed from registry.json
    And the removal is printed to stdout

  Scenario: clean removes an entry whose ID is no longer in its markdown file
    Given the registry records rq-9b4d2f1a as living in rqm/basis/guess.md
    And rq-9b4d2f1a no longer appears anywhere in rqm/basis/guess.md
    When rqm.sh clean is called
    Then rq-9b4d2f1a is removed from registry.json

  Scenario: clean removes a stale ref from a registry entry
    Given the registry entry for rq-9b4d2f1a includes a ref to src/guess.rs
    And src/guess.rs no longer contains rq-9b4d2f1a anywhere in the file
    When rqm.sh clean is called
    Then the ref to src/guess.rs is removed from the entry
    And the entry itself is retained

  Scenario: clean preserves a valid ref
    Given the registry entry for rq-9b4d2f1a includes a ref to src/guess.rs
    And src/guess.rs contains "rq-9b4d2f1a" somewhere in the file
    When rqm.sh clean is called
    Then the ref to src/guess.rs is retained in registry.json
```
