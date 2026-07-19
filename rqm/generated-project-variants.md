# Feature: Valid Generated Project Variants <!-- rq-a953fcc4 -->

Every supported answer combination renders a coherent project. Optional documentation describes
only artifacts that exist in the rendered or pre-existing project, and generated licensing material
contains the notices and complete license texts needed to communicate the selected terms.

## Python Documentation <!-- rq-51db1fdd -->

- A Python documentation skeleton is self-contained and buildable when it is rendered into an empty
  destination, whether or not Riprap also creates the Python package skeleton.
- Documentation generated with the Python package skeleton may include package installation and API
  references for the generated import package.
- Documentation generated without the Python package skeleton does not invent modules, install a
  nonexistent local package, or otherwise assume files that Riprap did not render. A project adding
  Riprap to an existing Python package may replace or extend the generic documentation with
  package-specific API material as user-owned content.
- Documentation dependencies and build instructions agree with the selected dependency source and
  with the files present in that project variant.

## License Distribution <!-- rq-5cab8102 -->

- Selecting MIT or BSD-3-Clause produces the complete selected license text and a project copyright
  notice containing the configured year and author.
- Selecting LGPL-3.0-or-later produces verbatim copies of both the GNU Lesser General Public License
  version 3 and the GNU General Public License version 3 on which it depends. The generated project
  also contains a separate project copyright notice and a clear statement that the project is
  licensed under LGPL-3.0-or-later.
- License metadata in generated language manifests uses the selected SPDX identifier and includes
  every generated license and notice file in distributable source and package artifacts.
- Selecting Not Open Source produces no open-source license text and does not claim an open-source
  SPDX license in a generated language manifest.
- License texts remain unmodified upstream legal texts. Project-specific names, authors, years, and
  explanatory notices live outside those verbatim texts.

## Gherkin Scenarios <!-- rq-7de9b8bd -->

```gherkin
Feature: Render coherent project variants

  @rq-5724d2c4
  Scenario: Documentation without a generated Python package is self-contained
    Given an empty destination
    And a Python project requests documentation without a Python package skeleton
    When the project is rendered
    Then the documentation does not reference a nonexistent project module
    And its dependency files do not install a nonexistent local package
    And the documented documentation-build command succeeds using only rendered files

  @rq-c39f2457
  Scenario: Documentation accompanies a generated Python package
    Given a Python project requests both documentation and a Python package skeleton
    When the project is rendered
    Then the documentation names the generated import package
    And its dependency files install the generated package
    And the documented documentation-build command succeeds

  @rq-197626f6
  Scenario: LGPL distribution includes its complete license basis
    Given a project selects "LGPL-3.0-or-later"
    When the project is rendered
    Then it contains verbatim LGPL version 3 and GPL version 3 license texts
    And it contains a separate project copyright and licensing notice
    And generated language metadata identifies the license as "LGPL-3.0-or-later"
    And every license and notice file is included in distributable package metadata

  @rq-3d28cd5f
  Scenario: Permissive licenses carry the project notice
    Given a project selects "MIT" or "BSD-3-Clause"
    When the project is rendered
    Then it contains the complete selected license text
    And the project copyright notice contains the configured year and author

  @rq-3eec4386
  Scenario: A closed-source project makes no open-source license claim
    Given a project selects "Not Open Source"
    When the project is rendered
    Then no open-source license text is generated
    And generated language metadata makes no open-source SPDX license claim
```
