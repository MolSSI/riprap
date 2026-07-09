# Development, testing, and deployment tools

This directory contains a collection of tools for running Continuous Integration (CI) tests,
conda installation, and other development tools not directly related to the coding process.


## Manifest

### Conda Environment:

This directory contains the files to setup the Conda environment for testing purposes

* `conda-envs`: directory containing the YAML file(s) which fully describe Conda Environments, their dependencies, and those dependency provenance's
  * `test_env.yaml`: Simple test environment file with base dependencies. Create it with `conda env create -f conda-envs/test_env.yaml`, then install the package into it with `pip install -e . --no-deps` from the repository root.


## Versioningit Auto-version

[Versioningit](https://versioningit.readthedocs.io/) will automatically infer what version
is installed by looking at the `git` tags and how many commits ahead this version is. The format follows
[PEP 440](https://www.python.org/dev/peps/pep-0440/). If the version of this commit is the same as a `git` tag,
the installed version is the same as the tag, otherwise it will be appended with `+X` where `X` is the number
of commits ahead from the last tag, followed by the `git` commit hash.
