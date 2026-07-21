#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY=python3

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

render_project() {
  copier copy --defaults --vcs-ref "${3:-HEAD}" \
    --data project_name='Permission Test' --data project_slug='permission-test' \
    --data project_description='Exercises shipped agent permission defaults' \
    --data language="$2" --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' --data open_source_license=MIT \
    "${4:-$ROOT}" "$1" >/dev/null
}

# Emits one shipped permission rule per line for the requested list.
rules() {
  "$PY" - "$1" "$2" <<'EOF'
import json, sys
settings = json.load(open(f"{sys.argv[1]}/.claude/settings.json"))
for rule in settings["permissions"].get(sys.argv[2], []):
    print(rule)
EOF
}

# The Bash command prefix a rule pre-approves, e.g. Bash(cargo test:*) -> "cargo test".
bash_prefix() {
  sed -n 's/^Bash(\(.*\):\*)$/\1/p; s/^Bash(\(.*\))$/\1/p' <<<"$1"
}

# rq-f40bdc52
# Riprap's skills invoke rqm.sh on every planning and implementation run. If that is not
# pre-approved, Riprap's own workflow prompts while broader grants pass silently.
test_shipped_defaults_cover_riprap_skill_commands() (
  local project="$1" command prefix covered
  while IFS= read -r command; do
    covered=no
    while IFS= read -r rule; do
      prefix="$(bash_prefix "$rule")"
      if [[ -n "$prefix" && "$command" == "$prefix"* ]]; then
        covered=yes
        break
      fi
    done < <(rules "$project" allow)
    test "$covered" = yes || fail "command a Riprap skill invokes is not pre-approved: $command"
  done < <(grep -rhoE '\.riprap/managed/skills/[a-z-]+/[a-z_]+\.sh' \
    "$ROOT"/template/.riprap/managed/skills/*/SKILL.md* | sort -u)
)

# rq-93f9b6ff
test_shipped_defaults_grant_no_interpreter_installer_or_shell() (
  local project="$1" rule prefix tool
  while IFS= read -r rule; do
    prefix="$(bash_prefix "$rule")"
    [[ -n "$prefix" ]] || continue
    tool="${prefix%% *}"
    tool="${tool##*/}"
    case "$tool" in
      python|python3|ruby|perl|node|deno|sh|bash|zsh|env|eval|xargs)
        fail "shipped allow rule grants a general interpreter or shell: $rule" ;;
      pip|pip3|conda|mamba|npm|pnpm|yarn|cargo-install|uv|poetry)
        fail "shipped allow rule grants a package installer: $rule" ;;
    esac
    # `cargo install` fetches and builds third-party code, unlike cargo's build/test subcommands.
    if [[ "$prefix" == "cargo install"* ]]; then
      fail "shipped allow rule grants a package installer: $rule"
    fi
  done < <(rules "$project" allow)
)

# rq-38ddfa1e
test_language_variants_grant_comparable_breadth() (
  local project="$1" language="$2" rule prefix tool allowed
  case "$language" in
    rust) allowed='cargo' ;;
    python) allowed='pytest pylint bandit' ;;
    *) fail "unknown language: $language" ;;
  esac
  while IFS= read -r rule; do
    prefix="$(bash_prefix "$rule")"
    [[ -n "$prefix" ]] || continue
    # Riprap's own tooling is granted for every language.
    if [[ "$prefix" == .riprap/* ]]; then
      continue
    fi
    tool="${prefix%% *}"
    grep -qw -- "$tool" <<<"$allowed" ||
      fail "$language grants an unexpected tool: $rule"
  done < <(rules "$project" allow)
  test -n "$(rules "$project" allow)" || fail "$language ships an empty allow list"
)

# rq-19afb5fd
test_credential_shaped_reads_are_denied() (
  local project="$1" path denied
  for path in ./.env ./.claude/.credentials.json ./.codex/auth.json ./.opencode/data/opencode/auth.json; do
    denied=no
    while IFS= read -r rule; do
      if [[ "$rule" == "Read($path)" ]]; then
        denied=yes
        break
      fi
    done < <(rules "$project" deny)
    test "$denied" = yes || fail "reading $path is not denied"
  done
)

# rq-53993832
test_opencode_receives_equivalent_defaults() (
  local project="$1" language="$2"
  "$PY" - "$project" "$language" <<'EOF'
import json, pathlib, sys

project = pathlib.Path(sys.argv[1])
language = sys.argv[2]
config = json.loads((project / "opencode.json").read_text())
assert config["autoupdate"] is False
bash = config["permission"]["bash"]
assert bash["*"] == "ask"
assert bash[".riprap/managed/skills/rr-plan/rqm.sh *"] == "allow"
expected = ["cargo test *"] if language == "rust" else ["pytest *", "pylint *", "bandit *"]
assert all(bash[item] == "allow" for item in expected)
for forbidden in ("python *", "python3 *", "bash *", "sh *", "npm *", "pip *", "cargo install *"):
    assert forbidden not in bash
read = config["permission"]["read"]
for secret in ("**/.env", "**/.env.*", "**/.claude/.credentials.json",
               "**/.codex/auth.json", "**/.opencode/data/opencode/auth.json"):
    assert read[secret] == "deny"
EOF
)

# Whether OpenCode honours the plugin is demonstrated by running OpenCode, which
# test_development_container.sh does against the built agent image. What remains here is the
# rendering of the plugin, and the one branch no Linux or macOS host can reach: a host that can
# run the containerized agent image is not a host that takes the Windows path.
# rq-91dd9910
test_opencode_container_check_is_rendered() (
  local project="$1" plugin
  plugin="$project/.opencode/plugins/check-container.js"
  test -f "$plugin" || fail 'OpenCode container-check plugin was not rendered'
  grep -Fq "process.platform === 'win32'" "$plugin" || fail 'host Windows OpenCode is not rejected'
)

# The canonical container check must recognise an Apptainer container, or every agent would be
# blocked on an execution host that runs an exported image. The Apptainer marker variable is
# evaluated before any host-specific probe, so this branch is deterministic on any host.
# rq-2430a9f0
test_container_check_recognizes_apptainer() (
  local project="$1" hook
  hook="$project/.riprap/managed/hooks/check-container.sh"
  test -f "$hook" || fail 'the container-check hook was not rendered'
  APPTAINER_CONTAINER=/opt/riprap/image.sif bash "$hook" >/dev/null 2>&1 ||
    fail 'the container check does not recognise an Apptainer container'
  SINGULARITY_CONTAINER=/opt/riprap/image.sif bash "$hook" >/dev/null 2>&1 ||
    fail 'the container check does not recognise a Singularity container'
)

# rq-f928505b
test_project_own_permissions_are_not_version_controlled() (
  local project="$1"
  git -C "$project" init --quiet
  mkdir -p "$project/.claude"
  printf '{"permissions":{"allow":[]}}\n' > "$project/.claude/settings.local.json"
  git -C "$project" check-ignore -q .claude/settings.local.json ||
    fail 'the agent user-local settings file is not ignored'
  ! git -C "$project" check-ignore -q .claude/settings.json ||
    fail 'the shipped settings file is ignored'
)

# rq-1016a30a
test_project_own_permissions_survive_a_template_update() (
  local temp source project
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  source="$temp/source"
  project="$temp/project"

  cp -a "$ROOT/." "$source/"
  rm -rf "$source/.git"
  git -C "$source" init --quiet
  git -C "$source" config user.name 'Riprap Tests'
  git -C "$source" config user.email 'riprap@example.com'
  git -C "$source" add .
  git -C "$source" commit --quiet -m 'template v1'
  git -C "$source" tag v1.0.0

  render_project "$project" rust v1.0.0 "$source"
  printf '{"permissions":{"allow":["Bash(just:*)"]}}\n' > "$project/.claude/settings.local.json"
  git -C "$project" init --quiet
  git -C "$project" config user.name 'Riprap Tests'
  git -C "$project" config user.email 'riprap@example.com'
  git -C "$project" add --force .
  git -C "$project" commit --quiet -m 'project records its own permission'

  "$PY" - "$source" <<'EOF'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]) / "template/.claude/settings.json.jinja"
t = p.read_text().replace('"deny": [', '"deny": [\n      "Read(./.netrc)",')
p.write_text(t)
EOF
  git -C "$source" add template/.claude/settings.json.jinja
  git -C "$source" commit --quiet -m 'template v2'
  git -C "$source" tag v2.0.0

  ( cd "$project" && copier update --defaults --vcs-ref v2.0.0 ) >/dev/null

  grep -Fq 'Bash(just:*)' "$project/.claude/settings.local.json" ||
    fail "the project's own permission did not survive the update"
  grep -Fq 'Read(./.netrc)' "$project/.claude/settings.json" ||
    fail 'the shipped configuration did not receive the later revision'
)

main() {
  local temp project language
  temp="$(mktemp -d)"; trap "rm -rf '$temp'" EXIT

  for language in rust python; do
    project="$temp/$language"
    render_project "$project" "$language"
    test_shipped_defaults_cover_riprap_skill_commands "$project"
    test_shipped_defaults_grant_no_interpreter_installer_or_shell "$project"
    test_language_variants_grant_comparable_breadth "$project" "$language"
    test_credential_shaped_reads_are_denied "$project"
    test_opencode_receives_equivalent_defaults "$project" "$language"
  done

  test_opencode_container_check_is_rendered "$temp/rust"
  test_container_check_recognizes_apptainer "$temp/rust"

  test_project_own_permissions_are_not_version_controlled "$temp/rust"
  test_project_own_permissions_survive_a_template_update
  printf 'PASS: agent permission defaults\n'
}

main "$@"
