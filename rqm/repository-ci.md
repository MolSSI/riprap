# Feature: Riprap Repository Continuous Integration <!-- rq-574589db -->

The Riprap repository validates proposed changes before merge and validates the resulting `main`
branch after integration. Branch pushes that are not part of a pull request do not create a second
repository CI run.

## Event Policy <!-- rq-6f163c7d -->

- The repository test workflow runs for every pull request, without restricting the pull request's
  base branch.
- The repository test workflow runs for pushes to `main`.
- The repository test workflow does not run for pushes to other branches or for tag pushes.
- Merging a pull request may therefore produce a pull-request run for the proposed revision and a
  separate push run for the integrated revision on `main`.

## Gherkin Scenarios <!-- rq-230de53f -->

```gherkin
Feature: Select repository events for continuous integration

  @rq-b4c43b87
  Scenario: Every pull request runs repository CI
    Given a pull request targets any branch in the Riprap repository
    When GitHub evaluates the repository test workflow triggers
    Then the pull request event selects the workflow

  @rq-0da67b01
  Scenario: A push to main runs repository CI
    Given a commit is pushed to the "main" branch
    When GitHub evaluates the repository test workflow triggers
    Then the push event selects the workflow

  @rq-f5edc2ae
  Scenario: Other pushes do not run repository CI
    Given a commit is pushed to a branch other than "main" or a tag is pushed
    When GitHub evaluates the repository test workflow triggers
    Then the push event does not select the workflow
```
