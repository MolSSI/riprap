# Feature: Template Traceability Boundary <!-- rq-cab43a04 -->

Guardrails keeps its own requirements traceability namespace outside the distributed `template/`
tree. Generated projects own independent requirements identifiers and registries, so Guardrails
implementation annotations cannot be mistaken for project-owned requirements.

## Traceability Rules <!-- rq-3105bde4 -->

- Guardrails requirements under the top-level `rqm/` directory use stable `rq-XXXXXXXX`
  identifiers.
- Top-level implementation and tests may reference those identifiers.
- No Guardrails identifier appears in any file under `template/`, including template
  implementations, scripts, tests, adapters, or generated documentation.
- An identifier is a Guardrails identifier when the top-level requirements registry records it.
  Validation resolves the forbidden set from that registry, so template content is judged against
  the identifiers Guardrails actually uses rather than against the identifier syntax.
- Template documentation, skill instructions, and test fixtures may contain illustrative
  identifiers that Guardrails does not use. These include non-concrete placeholders such as
  `rq-XXXXXXXX` and well-formed example values, which the fixtures for the requirements tooling
  need in order to exercise it.
- Validation examines every file under `template/`, including files in hidden directories, where
  most template content resides.
- Validation depends only on tooling present in the development container, so it produces the same
  result when run in the container and in continuous integration.
- The Guardrails registry does not record source references from `template/`.
- Generated repositories create and maintain their own identifiers and registry after generation.

## Gherkin Scenarios <!-- rq-f13ed893 -->

```gherkin
Feature: Separate Guardrails and generated-project traceability

  @rq-f63c0743
  Scenario: Guardrails traceability validation rejects a Guardrails ID in the template tree
    Given the requirements registry records a Guardrails requirement ID
    And that identifier appears in a file under "template/"
    When Guardrails traceability validation runs
    Then validation exits nonzero
    And it identifies the offending template path

  @rq-59ada47d
  Scenario: Validation examines hidden directories in the template tree
    Given the requirements registry records a Guardrails requirement ID
    And that identifier appears only in a file inside a hidden directory under "template/"
    When Guardrails traceability validation runs
    Then validation exits nonzero
    And it identifies the offending template path

  @rq-cb2cdd8e
  Scenario: Illustrative identifiers remain valid template content
    Given template documentation contains the non-concrete token "rq-XXXXXXXX"
    And a template test fixture contains a well-formed identifier the registry does not record
    When Guardrails traceability validation runs
    Then validation succeeds

  @rq-70d8296b
  Scenario: A generated project starts with an independent traceability namespace
    Given the Guardrails template contains no Guardrails requirement identifiers
    When a project is rendered with Copier
    And its requirements are stamped and indexed
    Then its registry contains only identifiers assigned within the generated project
    And the Guardrails repository registry is not copied into the generated project
```
