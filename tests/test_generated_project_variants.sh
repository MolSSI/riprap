#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

render_python() {
  local destination="$1" skeleton="$2" docs="$3" license="$4" dependencies="$5"
  copier copy --defaults --vcs-ref HEAD \
    --data project_name='Variant Test' --data project_slug='variant-test' \
    --data project_description='Exercises coherent generated variants' \
    --data language=python --data include_python_skeleton="$skeleton" \
    --data include_docs="$docs" --data dependency_source="$dependencies" \
    --data author_name='Variant Author' --data author_email='variant@example.com' \
    --data copyright_year=2042 --data open_source_license="$license" \
    "$ROOT" "$destination" >/dev/null
}

render_rust() {
  local destination="$1" license="$2"
  copier copy --defaults --vcs-ref HEAD \
    --data project_name='Variant Test' --data project_slug='variant-test' \
    --data project_description='Exercises coherent generated variants' \
    --data language=rust --data include_rust_skeleton=true \
    --data author_name='Variant Author' --data author_email='variant@example.com' \
    --data copyright_year=2042 --data open_source_license="$license" \
    "$ROOT" "$destination" >/dev/null
}

# rq-5724d2c4
test_docs_without_package_are_self_contained() (
  local temp project pip_project
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT; project="$temp/project"
  render_python "$project" false true 'Not Open Source' 'Prefer conda-forge with pip fallback'
  test ! -e "$project/pyproject.toml" || fail 'test premise: a package skeleton was rendered'
  ! grep -Rq -- '-e ../' "$project/docs" || fail 'package-free docs install a nonexistent package'
  ! grep -Eq '^[[:space:]]*- pip:[[:space:]]*$' "$project/docs/requirements.yaml" ||
    fail 'package-free conda docs contain an empty pip dependency group'
  ! grep -Eq '^import variant_test$' "$project/docs/conf.py" || fail 'package-free docs import a nonexistent package'
  grep -Fq 'makes no assumptions about importable module names' "$project/docs/api.rst" ||
    fail 'package-free API documentation invents a module'
  (cd "$project/docs" && python3 conf.py) || fail 'package-free documentation configuration does not execute'
  pip_project="$temp/pip-project"
  render_python "$pip_project" false true 'Not Open Source' 'Dependencies from pip only (no conda)'
  ! grep -Rq -- '-e ../' "$pip_project/docs" || fail 'pip-only package-free docs install a nonexistent package'
  grep -Fq 'sphinx' "$pip_project/docs/requirements.txt" || fail 'pip-only docs omit their build dependency'
)

# rq-c39f2457
test_docs_with_package_describe_generated_package() (
  local temp project
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT; project="$temp/project"
  render_python "$project" true true MIT 'Prefer conda-forge with pip fallback'
  test -f "$project/src/variant_test/variant_test.py" || fail 'generated package module is missing'
  grep -Eq '^import variant_test$' "$project/docs/conf.py" || fail 'docs do not import the generated package'
  grep -Fq 'variant_test.variant_test' "$project/docs/api.rst" || fail 'API page names a module that was not generated'
  grep -Fq -- '- -e ../' "$project/docs/requirements.yaml" || fail 'docs environment does not install the generated package'
)

# rq-197626f6
test_lgpl_distribution_is_complete() (
  local temp project rust_project
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT; project="$temp/project"
  render_python "$project" true false LGPL-3.0-or-later 'Dependencies from pip only (no conda)'
  cmp -s "$project/LICENSE" /usr/share/common-licenses/LGPL-3 || fail 'generated LGPL text is not verbatim LGPLv3'
  cmp -s "$project/LICENSE.GPL" /usr/share/common-licenses/GPL-3 || fail 'generated GPL text is not verbatim GPLv3'
  grep -Fq 'Copyright (c) 2042 Variant Author' "$project/NOTICE" || fail 'LGPL project notice lacks copyright'
  grep -Fq 'LGPL-3.0-or-later' "$project/NOTICE" || fail 'LGPL project notice lacks the selected terms'
  grep -Fq 'license = "LGPL-3.0-or-later"' "$project/pyproject.toml" || fail 'Python metadata lacks LGPL SPDX identifier'
  grep -Fq 'license-files = ["LICENSE", "LICENSE.GPL", "NOTICE"]' "$project/pyproject.toml" ||
    fail 'Python package metadata omits LGPL distribution files'
  rust_project="$temp/rust-project"
  render_rust "$rust_project" LGPL-3.0-or-later
  grep -Fq '"/LICENSE.GPL", "/NOTICE"' "$rust_project/Cargo.toml" ||
    fail 'Rust package metadata omits the LGPL distribution files'
)

# rq-3d28cd5f
test_permissive_licenses_carry_project_notice() (
  local temp project license
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  for license in MIT BSD-3-Clause; do
    project="$temp/$license"; render_rust "$project" "$license"
    grep -Fq '2042' "$project/LICENSE" || fail "$license lacks the configured copyright year"
    grep -Fq 'Variant Author' "$project/LICENSE" || fail "$license lacks the configured copyright holder"
    grep -Fq "license = \"$license\"" "$project/Cargo.toml" || fail "$license metadata is incorrect"
  done
)

# rq-3eec4386
test_closed_source_variant_makes_no_open_source_claim() (
  local temp project
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT; project="$temp/project"
  render_rust "$project" 'Not Open Source'
  test ! -e "$project/LICENSE" || fail 'closed-source project contains an open-source license'
  test ! -e "$project/LICENSE.GPL" || fail 'closed-source project contains a GPL license'
  test ! -e "$project/NOTICE" || fail 'closed-source project contains an LGPL notice'
  ! grep -Eq '^license(-file)?[[:space:]]*=' "$project/Cargo.toml" || fail 'closed-source manifest claims an open-source license'
)

test_docs_without_package_are_self_contained
test_docs_with_package_describe_generated_package
test_lgpl_distribution_is_complete
test_permissive_licenses_carry_project_notice
test_closed_source_variant_makes_no_open_source_claim
printf 'PASS: generated project variants are coherent\n'
