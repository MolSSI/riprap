# Feature: Template Traceability Boundary <!-- rq-cab43a04 -->

Guardrails keeps its own requirements traceability namespace outside the distributed `template/`
tree. Generated projects own independent requirements identifiers and registries, so Guardrails
implementation annotations cannot be mistaken for project-owned requirements.

## Traceability Rules <!-- rq-3105bde4 -->

- Guardrails requirements under the top-level `rqm/` directory use stable `rq-XXXXXXXX`
  identifiers.
- Top-level implementation and tests may reference those identifiers.
- No concrete Guardrails `rq-XXXXXXXX` identifier appears in any file under `template/`, including
  template implementations, scripts, tests, adapters, or generated documentation.
- Template documentation may describe the identifier syntax using an unmistakable non-concrete
  placeholder such as `rq-XXXXXXXX`.
- The Guardrails registry does not record source references from `template/`.
- Generated repositories create and maintain their own identifiers and registry after generation.

## Gherkin Scenarios <!-- rq-f13ed893 -->

```gherkin
Feature: Separate Guardrails and generated-project traceability

  @rq-f63c0743
  Scenario: Guardrails traceability validation rejects a concrete ID in the template tree
    Given a concrete Guardrails requirement ID appears in a file under "template/"
    When Guardrails traceability validation runs
    Then validation exits nonzero
    And it identifies the offending template path

  @rq-cb2cdd8e
  Scenario: Placeholder syntax remains valid template documentation
    Given template documentation contains the non-concrete token "rq-XXXXXXXX"
    And no concrete requirement ID appears under "template/"
    When Guardrails traceability validation runs
    Then validation succeeds

  @rq-70d8296b
  Scenario: A generated project starts with an independent traceability namespace
    Given the Guardrails template contains no concrete requirement IDs
    When a project is rendered with Copier
    And its requirements are stamped and indexed
    Then its registry contains only identifiers assigned within the generated project
    And the Guardrails repository registry is not copied into the generated project
```
