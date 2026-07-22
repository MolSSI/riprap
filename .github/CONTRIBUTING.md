# How to contribute

We welcome contributions from external contributors, and this document
describes how to merge code changes into Riprap.

## Getting Started

* Make sure you have a [GitHub account](https://github.com/signup/free).
* Install `pipx`, Podman, `strace`, and Copier 9 (`pipx install 'copier>=9,<10'`).
* [Fork](https://help.github.com/articles/fork-a-repo/) this repository on GitHub.
* On your local machine,
  [clone](https://help.github.com/articles/cloning-a-repository/) your fork of
  the repository.

## Making Changes

* Add some really awesome code to your local fork.  It's usually a [good
  idea](http://blog.jasonmeridth.com/posts/do-not-issue-pull-requests-from-your-master-branch/)
  to make changes on a
  [branch](https://help.github.com/articles/creating-and-deleting-branches-within-your-repository/)
  with the branch name relating to the feature you are going to add.
* When you are ready for others to examine and comment on your new feature,
  navigate to your fork of Riprap on GitHub and open a [pull
  request](https://help.github.com/articles/using-pull-requests/) (PR). Note that
  after you launch a PR from one of your fork's branches, all
  subsequent commits to that branch will be added to the open pull request
  automatically.  Each commit added to the PR will be validated for
  mergability, compilation and test suite compliance; the results of these tests
  will be visible on the PR page.
* If you're providing a new feature, update its requirements under `rqm/` first, then add tests,
  implementation, and documentation with requirement traceability.
* Before opening a pull request, run the Linux validation used by CI:

  ```bash
  bash tests/test_agent_neutral_skills.sh
  bash tests/check_template_ownership.sh
  bash tests/test_agent_permissions.sh
  bash tests/test_generated_project_variants.sh
  bash template/.riprap/managed/skills/rr-plan/tests/test_rqm.sh
  bash tests/check_template_traceability.sh
  bash tests/test_development_container.sh
  bash tests/test_credential_isolation.sh
  ```

  The development-container suite requires Podman and builds real images. Windows launcher changes
  must also pass `powershell -File .\tests\test_windows_launcher.ps1` on Windows; that suite uses a
  mock container runtime and does not require Podman.
* When you're ready to be considered for merging, check the "Ready to go"
  box on the PR page to let the Riprap devs know that the changes are complete.
  The code will not be merged until this box is checked, the continuous
  integration returns checkmarks,
  and multiple core developers give "Approved" reviews.

# Additional Resources

* [General GitHub documentation](https://help.github.com/)
* [PR best practices](http://codeinthehole.com/writing/pull-requests-and-other-good-practices-for-teams-using-github/)
* [A guide to contributing to software packages](http://www.contribution-guide.org)
* [Thinkful PR example](http://www.thinkful.com/learn/github-pull-request-tutorial/#Time-to-Submit-Your-First-PR)
