# Feature: Guardrails Development Container <!-- rq-da673d77 -->

The template-owned base container provides the common command-line tools needed to develop a
generated project and to apply or validate Guardrails template updates. Project-owned container
layers may add further tools without replacing the base tooling.

## Base Tooling <!-- rq-fc6358df -->

- The base image provides the Copier CLI for every supported project language.
- Copier is installed as an isolated Python CLI application with `pipx`.
- The installed Copier release is compatible with the template's declared minimum Copier major
  version.
- The `copier` executable is available on `PATH` in interactive development containers.

## Gherkin Scenarios <!-- rq-88b04d5f -->

```gherkin
Feature: Guardrails development container

  @rq-a32974ac
  Scenario: Copier is available in a generated Rust development container
    Given a Rust project is rendered from the Guardrails template with Copier
    When the generated template-owned base container image is built
    Then the image build succeeds
    And running "copier --version" in the built image succeeds
    And the reported Copier major version is compatible with the template

  @rq-876d30dd
  Scenario: Copier is available in a generated Python development container
    Given a Python project is rendered from the Guardrails template with Copier
    When the generated template-owned base container image is built
    Then the image build succeeds
    And running "copier --version" in the built image succeeds
    And the reported Copier major version is compatible with the template
```
