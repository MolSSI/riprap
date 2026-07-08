#!/usr/bin/env bash
# rqm.sh — Requirements traceability ID management
# Deps: bash >= 4.0, grep, find, sed, jq, od
set -euo pipefail

RQM_DIR="${RQM_DIR:-rqm}"
SRC_DIR="${SRC_DIR:-src}"
TESTS_DIR="${TESTS_DIR:-tests}"
REGISTRY="${RQM_DIR}/registry.json"
ID_PAT='rq-[0-9a-f]{8}'

declare -A _SEEN=()   # IDs seen during current stamp run

# ── Helpers ───────────────────────────────────────────────────────────────────

_gen_unique_id() {
  local id attempts=0
  while (( attempts < 100 )); do
    id="rq-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ -z "${_SEEN[$id]+x}" ]]; then
      _SEEN[$id]=1; printf '%s' "$id"; return
    fi
    (( attempts++ )) || true
  done
  echo "rqm: error: could not generate unique ID after 100 attempts" >&2
  exit 1
}

_load_ids() {
  # Add all rq- IDs found in FILE to _SEEN
  local file="$1" id
  while IFS= read -r id; do _SEEN[$id]=1
  done < <(grep -oE "$ID_PAT" "$file" 2>/dev/null || true)
}

_strip_annot() {
  # Strip one or more trailing <!-- rq-XXXXXXXX --> from a heading/bullet line.
  sed -E 's/([[:space:]]*<!-- rq-[0-9a-f]{8} -->[[:space:]]*)+$//' <<< "$1"
}

# Match the <!-- rq-XXXXXXXX --> annotation form with bash's built-in
# regex rather than spawning grep.  This runs per line during stamp, so
# avoiding the subprocess is a real saving.
_has_id() {
  local _annot_re='<!-- rq-[0-9a-f]{8} -->'
  [[ "$1" =~ $_annot_re ]]
}

_get_id() { grep -oE "$ID_PAT" <<< "$1" | head -1; }

# ── stamp: process one file in-place ─────────────────────────────────────────

_stamp_file() {
  local file="$1"
  local -a lines=() out=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$file"

  local fence=""   # "": none  "gherkin": gherkin  "other": other fence
  local in_api=false

  for (( i=0; i<${#lines[@]}; i++ )); do
    line="${lines[$i]}"

    # ── Fence transitions ──────────────────────────────────────────────────
    if [[ "$line" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
      fence=""; out+=("$line"); continue
    fi
    if [[ "$line" =~ ^\`\`\`gherkin[[:space:]]*$ ]]; then
      fence="gherkin"; out+=("$line"); continue
    fi
    if [[ "$line" =~ ^\`\`\`.+ ]]; then
      fence="other"; out+=("$line"); continue
    fi

    # ── Inside gherkin fence ───────────────────────────────────────────────
    if [[ "$fence" == "gherkin" ]]; then
      if [[ "$line" =~ ^([[:space:]]*)Scenario:[[:space:]] ]]; then
        # Save indent from this match BEFORE the next [[ =~ ]] overwrites BASH_REMATCH
        local indent="${BASH_REMATCH[1]}"
        local last="${out[-1]:-}"
        if ! [[ "$last" =~ ^[[:space:]]*@rq-[0-9a-f]{8}[[:space:]]*$ ]]; then
          local new_id; new_id=$(_gen_unique_id)
          out+=("${indent}@${new_id}")
        fi
      fi
      out+=("$line"); continue
    fi

    # ── Inside non-gherkin fence: pass through ─────────────────────────────
    if [[ "$fence" == "other" ]]; then
      out+=("$line"); continue
    fi

    # ── Normal markdown ────────────────────────────────────────────────────

    # Headings # ## ### #### ##### ###### (levels 1-6)
    if [[ "$line" =~ ^(#{1,6})[[:space:]] ]]; then
      local hashes="${BASH_REMATCH[1]}" level
      level=${#hashes}
      # Track Feature API section
      if [[ $level -le 2 ]]; then
        local stripped; stripped=$(sed -E 's/^#{1,6} //' <<< "$(_strip_annot "$line")")
        if [[ $level -eq 2 && "$stripped" == "Feature API" ]]; then
          in_api=true
        elif [[ $level -le 2 ]]; then
          in_api=false
        fi
      fi
      # level-1 always resets API tracking
      [[ $level -eq 1 ]] && in_api=false
      # Add ID if missing
      if ! _has_id "$line"; then
        local new_id; new_id=$(_gen_unique_id)
        line="${line} <!-- ${new_id} -->"
      fi
      out+=("$line"); continue
    fi

    # API item bullets: top-level "- `..." inside Feature API section
    if $in_api && [[ "$line" =~ ^-[[:space:]]\` ]]; then
      if ! _has_id "$line"; then
        local new_id; new_id=$(_gen_unique_id)
        line="${line} <!-- ${new_id} -->"
      fi
      out+=("$line"); continue
    fi

    out+=("$line")
  done

  printf '%s\n' "${out[@]}" > "$file"
}

# ── stamp --fix-duplicates ────────────────────────────────────────────────────

_fix_duplicates() {
  local -a files=("$@")
  local exit_code=0

  # Load stored decls from registry (id -> decl)
  declare -A reg_decl=()
  if [[ -f "$REGISTRY" ]]; then
    local id decl
    while IFS=$'\t' read -r id decl; do
      reg_decl[$id]="$decl"
    done < <(jq -r 'to_entries[] | [.key, (.value.decl // "")] | @tsv' "$REGISTRY" 2>/dev/null || true)
  fi

  # Collect all id -> list-of-(file,lineno,decl,fullline) occurrences
  # Store as: id__count, id__file_N, id__lineno_N, id__decl_N
  declare -A occ_count=()
  declare -A occ_file=() occ_lineno=() occ_decl=()

  local f
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    local fence="" in_api=false prev_rq_id="" prev_rq_lineno=0
    local lineno=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
      (( lineno++ )) || true

      if [[ "$line" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
        fence=""; continue
      fi
      if [[ "$line" =~ ^\`\`\`gherkin[[:space:]]*$ ]]; then
        fence="gherkin"; continue
      fi
      if [[ "$line" =~ ^\`\`\`.+ ]]; then
        fence="other"; continue
      fi

      if [[ "$fence" == "gherkin" ]]; then
        if [[ "$line" =~ ^[[:space:]]*@(rq-[0-9a-f]{8})[[:space:]]*$ ]]; then
          prev_rq_id="${BASH_REMATCH[1]}"; prev_rq_lineno=$lineno
        elif [[ "$line" =~ ^[[:space:]]*Scenario:[[:space:]] ]]; then
          if [[ -n "$prev_rq_id" ]]; then
            local id="$prev_rq_id"
            local decl; decl=$(sed -E 's/^[[:space:]]*//' <<< "$line")
            local n="${occ_count[$id]:-0}"
            occ_count[$id]=$(( n + 1 ))
            occ_file["${id}__${n}"]="$f"
            occ_lineno["${id}__${n}"]="$prev_rq_lineno"
            occ_decl["${id}__${n}"]="$decl"
          fi
          prev_rq_id=""
        else
          prev_rq_id=""
        fi
        continue
      fi

      [[ "$fence" != "" ]] && continue

      if [[ "$line" =~ ^(#{1,6})[[:space:]] ]]; then
        # Capture the heading-hash count BEFORE calling _has_id, which
        # runs its own regex match and would otherwise clobber BASH_REMATCH.
        local hashes="${BASH_REMATCH[1]}"
        if _has_id "$line"; then
          local id; id=$(_get_id "$line")
          local decl; decl=$(_strip_annot "$line")
          local n="${occ_count[$id]:-0}"
          occ_count[$id]=$(( n + 1 ))
          occ_file["${id}__${n}"]="$f"
          occ_lineno["${id}__${n}"]="$lineno"
          occ_decl["${id}__${n}"]="$decl"
          local level=${#hashes}
          local stripped; stripped=$(sed -E 's/^#{1,6} //' <<< "$decl")
          [[ $level -eq 2 && "$stripped" == "Feature API" ]] && in_api=true
          [[ $level -eq 2 && "$stripped" != "Feature API" ]] && in_api=false
          [[ $level -eq 1 ]] && in_api=false
          continue
        fi
      fi

      if $in_api && [[ "$line" =~ ^-[[:space:]]\` ]] && _has_id "$line"; then
        local id; id=$(_get_id "$line")
        local decl; decl=$(_strip_annot "$line")
        local n="${occ_count[$id]:-0}"
        occ_count[$id]=$(( n + 1 ))
        occ_file["${id}__${n}"]="$f"
        occ_lineno["${id}__${n}"]="$lineno"
        occ_decl["${id}__${n}"]="$decl"
      fi
    done < "$f"
  done

  # Process duplicates
  local id
  for id in "${!occ_count[@]}"; do
    local n="${occ_count[$id]}"
    (( n < 2 )) && continue

    if (( n > 2 )); then
      echo "Unresolvable: ${id} appears ${n} times (more than 2 copies; resolve manually)" >&2
      exit_code=1; continue
    fi

    local f0="${occ_file["${id}__0"]}" l0="${occ_lineno["${id}__0"]}" d0="${occ_decl["${id}__0"]}"
    local f1="${occ_file["${id}__1"]}" l1="${occ_lineno["${id}__1"]}" d1="${occ_decl["${id}__1"]}"
    local stored="${reg_decl[$id]:-}"

    local orig_idx=-1
    if [[ -z "$stored" ]]; then
      echo "Unresolvable: ${id} — no prior registry to identify original" >&2
      echo "  ${f0}:${l0}: ${d0}" >&2
      echo "  ${f1}:${l1}: ${d1}" >&2
      echo "manually remove the ${id} annotation from one of the above lines." >&2
      exit_code=1; continue
    fi
    [[ "$d0" == "$stored" ]] && orig_idx=0
    [[ "$d1" == "$stored" ]] && orig_idx=1
    if [[ "$d0" == "$stored" && "$d1" == "$stored" ]]; then orig_idx=-1; fi

    if [[ $orig_idx -eq -1 ]]; then
      echo "Unresolvable: ${id}" >&2
      echo "  ${f0}:${l0}: ${d0}" >&2
      echo "  ${f1}:${l1}: ${d1}" >&2
      echo "manually remove the ${id} annotation from one of the above lines." >&2
      exit_code=1; continue
    fi

    # orig_idx identifies the original; the other is the copy to re-stamp
    local copy_f copy_l
    if [[ $orig_idx -eq 0 ]]; then copy_f="$f1"; copy_l="$l1"
    else                            copy_f="$f0"; copy_l="$l0"; fi

    _load_ids "$copy_f"
    local new_id; new_id=$(_gen_unique_id)
    # Replace the ID on line copy_l (could be @rq- tag or inline comment)
    sed -i "${copy_l}s/${id}/${new_id}/" "$copy_f"
    echo "FIXED: ${copy_f}:${copy_l}: replaced ${id} with ${new_id}"
  done

  return $exit_code
}

# ── cmd_stamp ─────────────────────────────────────────────────────────────────

cmd_stamp() {
  local fix=false
  local -a files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix-duplicates) fix=true; shift ;;
      *) files+=("$1"); shift ;;
    esac
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    while IFS= read -r f; do files+=("$f")
    done < <(find "$RQM_DIR" -name '*.md' -type f | sort)
  fi

  if $fix; then _fix_duplicates "${files[@]}"; return; fi

  # Preload all IDs across all target files for cross-file uniqueness
  local f
  for f in "${files[@]}"; do _load_ids "$f"; done
  for f in "${files[@]}"; do _stamp_file "$f"; done
}

# ── Markdown entity scanner (used by index) ───────────────────────────────────
# A single awk program scans every rqm markdown file passed as an argument
# and emits one tab-separated record per entity:
#
#   id <TAB> type <TAB> file <TAB> title <TAB> decl <TAB> level
#
# (level is empty except for headings).  A downstream `jq -R` pass converts
# the TSV stream to the JSONL the rest of cmd_index consumes.  Doing the
# whole scan in one process — instead of a bash line-loop that forks jq/sed/
# grep per entity — is what keeps `index` fast as the docs grow.
RQM_SCAN_AWK='
BEGIN {
  HEX8  = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
  ANNOT = "<!-- rq-" HEX8 " -->"
}

function has_id(s) { return (s ~ ANNOT) }

# Strip one or more trailing <!-- rq-XXXXXXXX --> annotations.
function strip_annot(s,   t) {
  t = s
  while (sub(("[[:space:]]*" ANNOT "[[:space:]]*$"), "", t)) { }
  return t
}

# Strip every <!-- rq-XXXXXXXX --> annotation anywhere in the line,
# collapsing surrounding whitespace and trimming the ends.
function strip_all_annot(s,   t) {
  t = s
  gsub(("[[:space:]]*" ANNOT "[[:space:]]*"), " ", t)
  sub(/^[[:space:]]+/, "", t)
  sub(/[[:space:]]+$/, "", t)
  return t
}

# Remove a leading "#"(1-6) + single space, mirroring sed s/^#{1,6} //.
function strip_heading(s) {
  if (match(s, /^#+ /) && (RLENGTH - 1) <= 6)
    return substr(s, RLENGTH + 1)
  return s
}

# Identifier title for a Feature-API bullet, mirroring
# sed s/^- `([A-Za-z_][A-Za-z0-9_]*).*/\1/.
function api_title(s) {
  if (match(s, /^- `[A-Za-z_][A-Za-z0-9_]*/))
    return substr(s, 4, RLENGTH - 3)
  return s
}

# Fill ID_LIST[1..ID_N] with the distinct rq-IDs on a line, in order.
function collect_ids(s,   t, id, k, dup) {
  ID_N = 0
  t = s
  while (match(t, ("rq-" HEX8))) {
    id = substr(t, RSTART, RLENGTH)
    dup = 0
    for (k = 1; k <= ID_N; k++) if (ID_LIST[k] == id) { dup = 1; break }
    if (!dup) { ID_N++; ID_LIST[ID_N] = id }
    t = substr(t, RSTART + RLENGTH)
  }
}

function emit(id, type, file, title, decl, level,   tt, dd) {
  tt = title; gsub("\t", " ", tt)
  dd = decl;  gsub("\t", " ", dd)
  print id "\t" type "\t" file "\t" tt "\t" dd "\t" level
}

FNR == 1 {
  fence = ""; in_api = 0; prev_rq_id = ""
  rel = FILENAME
  if (substr(rel, 1, length(rqmdir) + 1) == (rqmdir "/"))
    rel = substr(rel, length(rqmdir) + 2)
  if (substr(rel, length(rel) - 2) == ".md")
    rel = substr(rel, 1, length(rel) - 3)
}

{
  line = $0

  # ── Fence transitions ──
  if (line ~ /^[[:space:]]*```[[:space:]]*$/) { fence = "";        next }
  if (line ~ /^```gherkin[[:space:]]*$/)      { fence = "gherkin"; next }
  if (line ~ /^```.+/)                        { fence = "other";   next }

  # ── Inside gherkin fence ──
  if (fence == "gherkin") {
    if (line ~ ("^[[:space:]]*@rq-" HEX8 "[[:space:]]*$")) {
      match(line, ("rq-" HEX8))
      prev_rq_id = substr(line, RSTART, RLENGTH)
    } else if (line ~ /^[[:space:]]*Scenario:[[:space:]].+$/) {
      if (prev_rq_id != "") {
        title = line
        sub(/^[[:space:]]*Scenario:[[:space:]]/, "", title)
        emit(prev_rq_id, "scenario", rel, title, "Scenario: " title, "")
      }
      prev_rq_id = ""
    } else {
      prev_rq_id = ""
    }
    next
  }

  # ── Inside a non-gherkin fence: pass through ──
  if (fence != "") next

  # ── Headings, levels 1-6 ──
  if (match(line, /^#+/) && RLENGTH >= 1 && RLENGTH <= 6 \
      && substr(line, RLENGTH + 1, 1) ~ /[[:space:]]/) {
    level = RLENGTH
    if (has_id(line)) {
      decl = strip_annot(line)
      raw_title = strip_heading(decl)
      etype = (level == 1) ? "file" : "section"
      collect_ids(line)
      for (k = 1; k <= ID_N; k++)
        emit(ID_LIST[k], etype, rel, raw_title, decl, level)
    } else {
      raw_title = strip_heading(line)
    }
    if (level == 2) in_api = (raw_title == "Feature API") ? 1 : 0
    if (level == 1) in_api = 0
    next
  }

  # ── Feature API bullets: top-level "- `..." inside the API section ──
  if (in_api && line ~ /^-[[:space:]]`/ && has_id(line)) {
    decl = strip_annot(line)
    title = api_title(decl)
    collect_ids(line)
    for (k = 1; k <= ID_N; k++)
      emit(ID_LIST[k], "api-item", rel, title, decl, "")
    next
  }

  # ── Inline anchors: any other annotated line ──
  if (has_id(line)) {
    decl = strip_all_annot(line)
    title = substr(decl, 1, 80)
    collect_ids(line)
    for (k = 1; k <= ID_N; k++)
      emit(ID_LIST[k], "anchor", rel, title, decl, "")
  }
}
'

# ── cmd_index ─────────────────────────────────────────────────────────────────

cmd_index() {
  # 1. Collect all entities from rqm markdown files.  One awk pass over the
  #    whole tree emits TSV; a single jq converts it to the JSONL the rest
  #    of this function consumes.
  local entities_tmp; entities_tmp=$(mktemp)
  local -a rqm_files=()
  local f
  while IFS= read -r f; do rqm_files+=("$f")
  done < <(find "$RQM_DIR" -name '*.md' -type f | sort)
  if (( ${#rqm_files[@]} > 0 )); then
    awk -v rqmdir="$RQM_DIR" "$RQM_SCAN_AWK" "${rqm_files[@]}" \
      | jq -R 'split("\t")
          | {id: .[0], type: .[1], file: .[2], title: .[3], decl: .[4]}
          + (if .[5] != "" then {level: (.[5] | tonumber)} else {} end)' \
      > "$entities_tmp"
  fi

  # 1b. Anchors are inline-prose markers that mirror an ID for cross-reference.
  # When the same ID is also declared as a section / api-item / scenario, the
  # canonical declaration wins and the anchor is dropped (the markdown file
  # carrying the anchor still counts as a *reference* to the declaration via
  # the source-file scan in step 4).  Anchors with no canonical declaration
  # remain as first-class entities.
  local filtered_tmp; filtered_tmp=$(mktemp)
  jq -cs '
    group_by(.id)
    | map(
        if any(.[]; .type != "anchor") then
          map(select(.type != "anchor"))
        else
          .
        end
      )
    | flatten
    | .[]
  ' "$entities_tmp" > "$filtered_tmp"
  mv "$filtered_tmp" "$entities_tmp"

  # 2. Check for duplicate IDs
  local dupes; dupes=$(jq -r '.[].id' < <(jq -s '.' "$entities_tmp") | sort | uniq -d || true)
  if [[ -n "$dupes" ]]; then
    local had_error=false
    local dup_id
    while IFS= read -r dup_id; do
      had_error=true
      # Get list of conflicting entities
      local conflicts; conflicts=$(jq -r --arg id "$dup_id" \
        '.[] | select(.id==$id) | "\(.file): \"\(.decl)\""' \
        < <(jq -s '.' "$entities_tmp"))
      # Look up stored decl in existing registry
      local stored_decl=""
      if [[ -f "$REGISTRY" ]]; then
        stored_decl=$(jq -r --arg id "$dup_id" \
          'if has($id) then .[$id].decl else "" end' "$REGISTRY" 2>/dev/null || true)
      fi

      echo "ERROR: Duplicate ID ${dup_id}" >&2
      local orig_marked=false
      while IFS= read -r conflict_line; do
        if [[ -z "$stored_decl" ]]; then
          echo "  ${conflict_line}" >&2
        else
          local cdecl; cdecl=$(sed -E 's/^[^"]*"(.*)"/\1/' <<< "$conflict_line")
          if [[ "$cdecl" == "$stored_decl" ]] && ! $orig_marked; then
            echo "  ${conflict_line} [likely original - matches stored decl]" >&2
            orig_marked=true
          else
            echo "  ${conflict_line} [likely copy - decl changed]" >&2
          fi
        fi
      done <<< "$conflicts"

      if [[ -z "$stored_decl" ]]; then
        echo "  (no prior registry available to identify the original)" >&2
        echo "  manually remove the ${dup_id} annotation from one of the above lines." >&2
      elif ! $orig_marked; then
        echo "  Unresolvable: neither conflict matches the stored decl." >&2
        echo "  manually remove the ${dup_id} annotation from one of the above lines." >&2
      else
        echo "  Run: ./rqm.sh stamp --fix-duplicates" >&2
      fi
    done <<< "$dupes"
    rm -f "$entities_tmp"
    $had_error && exit 1
  fi

  # 3. Build base registry object (no refs yet)
  local registry
  registry=$(jq -s '
    reduce .[] as $e ({};
      . + {
        ($e.id): (
          { type: $e.type, file: $e.file, title: $e.title, decl: $e.decl, refs: [] }
          | if $e.type == "section" then . + {level: $e.level} else . end
        )
      }
    )
  ' "$entities_tmp")
  rm -f "$entities_tmp"

  # 4. Scan source + tests + rqm files for ID references — a single recursive
  #    grep over the tree, deduplicated per (file, id), converted by one jq pass.
  local refs_tmp; refs_tmp=$(mktemp)
  local -a scan_paths=("$SRC_DIR" "$RQM_DIR")
  if [[ -d "$TESTS_DIR" ]]; then scan_paths+=("$TESTS_DIR"); fi
  grep -rEo "$ID_PAT" "${scan_paths[@]}" \
      --include='*.rs' --include='*.md' 2>/dev/null \
    | sort -u \
    | jq -R 'rindex(":") as $i
        | {id: .[$i+1:], file: (.[:$i] | ltrimstr("./"))}' \
    > "$refs_tmp" || true

  # 5. Merge refs into registry (deduplicate by file, skip declaration self-refs)
  registry=$(jq -s --arg rqm_dir "$RQM_DIR" '
    .[0] as $reg |
    .[1:] |
    reduce .[] as $ref ($reg;
      if has($ref.id) then
        (($rqm_dir + "/" + $reg[$ref.id].file + ".md") == $ref.file) as $is_self |
        if $is_self | not then
          .[$ref.id].refs += [{"kind": "code", "file": $ref.file}] |
          .[$ref.id].refs |= (group_by(.file) | map(.[0]))
        else . end
      else . end
    )
  ' <(echo "$registry") "$refs_tmp")
  rm -f "$refs_tmp"

  # 6. Write registry
  echo "$registry" | jq --sort-keys '.' > "$REGISTRY"
  echo "index: wrote ${REGISTRY}"
}

# ── cmd_check ─────────────────────────────────────────────────────────────────

cmd_check() {
  if [[ ! -f "$REGISTRY" ]]; then
    echo "check: error: ${REGISTRY} not found; run ./rqm.sh index first" >&2
    exit 1
  fi

  local exit_code=0

  # Preload registry keys into an associative array. The previous shape spawned
  # one `jq` subprocess per `rq-` reference; with thousands of references in a
  # mature project this dominated runtime (~30 min on this project). A single
  # `jq keys[]` invocation plus O(1) bash lookups brings the check to under a
  # second.
  declare -A REGISTRY_KEYS
  while IFS= read -r k; do
    REGISTRY_KEYS[$k]=1
  done < <(jq -r 'keys[]' "$REGISTRY")

  # Collect all IDs referenced in source files
  while IFS= read -r src; do
    local rel_src="${src#./}"
    while IFS= read -r ref_id; do
      if [[ -z "${REGISTRY_KEYS[$ref_id]+x}" ]]; then
        echo "STALE: ${rel_src} references ${ref_id} (not in registry)" >&2
        exit_code=1
      fi
    done < <(grep -oE "$ID_PAT" "$src" 2>/dev/null | sort -u || true)
  done < <(
    find "$SRC_DIR" -name '*.rs' -type f 2>/dev/null | sort
    if [[ -d "$TESTS_DIR" ]]; then
      find "$TESTS_DIR" -name '*.rs' -type f 2>/dev/null | sort
    fi
    find "$RQM_DIR" -name '*.md' -type f 2>/dev/null | sort
  )

  # Warn about unreferenced requirements
  while IFS= read -r id; do
    echo "WARNING: ${id} has no references"
  done < <(jq -r 'to_entries[] | select((.value.refs | length) == 0) | .key' "$REGISTRY" 2>/dev/null || true)

  return $exit_code
}

# ── cmd_clean ─────────────────────────────────────────────────────────────────

cmd_clean() {
  if [[ ! -f "$REGISTRY" ]]; then
    echo "clean: error: ${REGISTRY} not found" >&2; exit 1
  fi

  local registry; registry=$(cat "$REGISTRY")
  local changed=false

  # Process each entry
  local updated="{}"
  local id
  while IFS= read -r id; do
    local entry; entry=$(jq -r --arg id "$id" '.[$id]' "$REGISTRY")
    local file; file=$(jq -r '.file' <<< "$entry")
    local md_file="${RQM_DIR}/${file}.md"

    # Remove entry if markdown file is gone
    if [[ ! -f "$md_file" ]]; then
      echo "REMOVED entry ${id} (${md_file} does not exist)"
      changed=true; continue
    fi

    # Remove entry if ID no longer in its markdown file
    if ! grep -qE "$id" "$md_file" 2>/dev/null; then
      echo "REMOVED entry ${id} (no longer in ${md_file})"
      changed=true; continue
    fi

    # Filter refs: keep only those where source file exists and contains the ID
    local cleaned_refs
    cleaned_refs=$(jq -r '.refs[].file' <<< "$entry" | while IFS= read -r ref_file; do
      if [[ -f "$ref_file" ]] && grep -qE "$id" "$ref_file" 2>/dev/null; then
        echo "$ref_file"
      else
        echo "REMOVED ref ${id} -> ${ref_file}" >&2
        changed=true
      fi
    done)

    local new_refs_json
    new_refs_json=$(printf '%s\n' $cleaned_refs | \
      jq -Rn '[inputs | select(length > 0) | {"kind":"code","file":.}]')

    local orig_refs_count; orig_refs_count=$(jq '.refs | length' <<< "$entry")
    local new_refs_count; new_refs_count=$(jq 'length' <<< "$new_refs_json")
    if (( new_refs_count < orig_refs_count )); then changed=true; fi

    local new_entry; new_entry=$(jq --argjson refs "$new_refs_json" '.refs = $refs' <<< "$entry")
    updated=$(jq --arg id "$id" --argjson e "$new_entry" '. + {($id): $e}' <<< "$updated")

  done < <(jq -r 'keys[]' "$REGISTRY")

  echo "$updated" | jq --sort-keys '.' > "$REGISTRY"
  $changed || echo "clean: nothing to remove"
}

# ── cmd_show ─────────────────────────────────────────────────────────────────

cmd_show() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    echo "show: error: ID required (e.g. rqm.sh show rq-3a7f1c2e)" >&2; exit 1
  fi
  if [[ ! -f "$REGISTRY" ]]; then
    echo "show: error: ${REGISTRY} not found; run ./rqm.sh index first" >&2; exit 1
  fi

  local entry
  entry=$(jq -e --arg id "$id" '.[$id] // empty' "$REGISTRY" 2>/dev/null || true)
  if [[ -z "$entry" ]]; then
    echo "show: ${id} not found in registry" >&2; exit 1
  fi

  local type file title decl
  type=$(jq -r '.type'  <<< "$entry")
  file=$(jq -r '.file'  <<< "$entry")
  title=$(jq -r '.title' <<< "$entry")
  decl=$(jq -r '.decl'  <<< "$entry")

  echo "ID:    ${id}"
  echo "Type:  ${type}"
  echo "File:  ${RQM_DIR}/${file}.md"
  echo "Title: ${title}"
  echo "Decl:  ${decl}"

  local refs; refs=$(jq -r '.refs[].file' <<< "$entry" 2>/dev/null || true)
  if [[ -n "$refs" ]]; then
    echo "Refs:"
    while IFS= read -r ref; do echo "  ${ref}"; done <<< "$refs"
  else
    echo "Refs:  (none)"
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 <stamp|index|check|clean|show> [--fix-duplicates] [files...]" >&2
  exit 1
}

case "${1:-}" in
  stamp) shift; cmd_stamp "$@" ;;
  index) shift; cmd_index ;;
  check) shift; cmd_check ;;
  clean) shift; cmd_clean ;;
  show)  shift; cmd_show "$@" ;;
  *) usage ;;
esac
