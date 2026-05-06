#!/usr/bin/env bash
# rqm.sh — Requirements traceability ID management
# Deps: bash >= 4.0, grep, find, sed, jq, od
set -euo pipefail

RQM_DIR="${RQM_DIR:-rqm}"
SRC_DIR="${SRC_DIR:-src}"
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
  # Strip trailing <!-- rq-XXXXXXXX --> from a heading/bullet line
  sed -E 's/[[:space:]]*<!-- rq-[0-9a-f]{8} -->[[:space:]]*$//' <<< "$1"
}

_has_id() { grep -qE '<!-- rq-[0-9a-f]{8} -->' <<< "$1"; }

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

    # Headings # ## ### (levels 1-3)
    if [[ "$line" =~ ^(#{1,3})[[:space:]] ]]; then
      local hashes="${BASH_REMATCH[1]}" level
      level=${#hashes}
      # Track Feature API section
      if [[ $level -le 2 ]]; then
        local stripped; stripped=$(sed -E 's/^#{1,3} //' <<< "$(_strip_annot "$line")")
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

      if [[ "$line" =~ ^(#{1,3})[[:space:]] ]] && _has_id "$line"; then
        local id; id=$(_get_id "$line")
        local decl; decl=$(_strip_annot "$line")
        local n="${occ_count[$id]:-0}"
        occ_count[$id]=$(( n + 1 ))
        occ_file["${id}__${n}"]="$f"
        occ_lineno["${id}__${n}"]="$lineno"
        occ_decl["${id}__${n}"]="$decl"
        local hashes="${BASH_REMATCH[1]}"
        local level=${#hashes}
        local stripped; stripped=$(sed -E 's/^#{1,3} //' <<< "$decl")
        [[ $level -eq 2 && "$stripped" == "Feature API" ]] && in_api=true
        [[ $level -eq 2 && "$stripped" != "Feature API" ]] && in_api=false
        [[ $level -eq 1 ]] && in_api=false
        continue
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
# Writes one JSON object per line (JSONL) to stdout for each entity found.

_scan_entities() {
  local file="$1"
  local rel="${file#"$RQM_DIR/"}"
  rel="${rel%.md}"

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
      elif [[ "$line" =~ ^[[:space:]]*Scenario:[[:space:]](.+)$ ]]; then
        if [[ -n "$prev_rq_id" ]]; then
          local title="${BASH_REMATCH[1]}"
          local decl="Scenario: ${title}"
          jq -cn --arg id "$prev_rq_id" --arg type "scenario" \
            --arg file "$rel" --arg title "$title" --arg decl "$decl" \
            '{id:$id,type:$type,file:$file,title:$title,decl:$decl}'
        fi
        prev_rq_id=""
      else
        prev_rq_id=""
      fi
      continue
    fi

    [[ "$fence" != "" ]] && continue

    if [[ "$line" =~ ^(#{1,3})[[:space:]] ]] && _has_id "$line"; then
      local hashes="${BASH_REMATCH[1]}" level
      level=${#hashes}
      local id; id=$(_get_id "$line")
      local decl; decl=$(_strip_annot "$line")
      local raw_title; raw_title=$(sed -E 's/^#{1,3} //' <<< "$decl")
      local etype="section"
      [[ $level -eq 1 ]] && etype="file"
      jq -cn --arg id "$id" --arg type "$etype" --arg file "$rel" \
        --arg title "$raw_title" --arg decl "$decl" --argjson level "$level" \
        '{id:$id,type:$type,file:$file,title:$title,decl:$decl,level:$level}'
      # Track API section
      if [[ $level -eq 2 ]]; then
        [[ "$raw_title" == "Feature API" ]] && in_api=true || in_api=false
      fi
      [[ $level -eq 1 ]] && in_api=false
      continue
    fi

    # Heading without ID: still update API tracking
    if [[ "$line" =~ ^(#{1,3})[[:space:]] ]]; then
      local hashes="${BASH_REMATCH[1]}" level; level=${#hashes}
      local raw_title; raw_title=$(sed -E 's/^#{1,3} //' <<< "$line")
      if [[ $level -eq 2 ]]; then
        [[ "$raw_title" == "Feature API" ]] && in_api=true || in_api=false
      fi
      [[ $level -eq 1 ]] && in_api=false
      continue
    fi

    if $in_api && [[ "$line" =~ ^-[[:space:]]\` ]] && _has_id "$line"; then
      local id; id=$(_get_id "$line")
      local decl; decl=$(_strip_annot "$line")
      local title; title=$(sed -E 's/^- `([A-Za-z_][A-Za-z0-9_]*).*/\1/' <<< "$decl")
      jq -cn --arg id "$id" --arg type "api-item" --arg file "$rel" \
        --arg title "$title" --arg decl "$decl" \
        '{id:$id,type:$type,file:$file,title:$title,decl:$decl}'
    fi
  done < "$file"
}

# ── cmd_index ─────────────────────────────────────────────────────────────────

cmd_index() {
  # 1. Collect all entities from rqm markdown files
  local entities_tmp; entities_tmp=$(mktemp)
  local f
  while IFS= read -r f; do
    _scan_entities "$f"
  done < <(find "$RQM_DIR" -name '*.md' -type f | sort) > "$entities_tmp"

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

  # 4. Scan source files for ID references
  local refs_tmp; refs_tmp=$(mktemp)
  while IFS= read -r src; do
    local rel_src="${src}"
    # Remove leading ./
    rel_src="${rel_src#./}"
    while IFS= read -r ref_id; do
      jq -cn --arg id "$ref_id" --arg file "$rel_src" '{id:$id,file:$file}'
    done < <(grep -oE "$ID_PAT" "$src" 2>/dev/null | sort -u || true)
  done < <(
    find "$SRC_DIR" -name '*.rs' -type f 2>/dev/null | sort
    find "$RQM_DIR" -name '*.md' -type f 2>/dev/null | sort
  ) > "$refs_tmp"

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

  # Collect all IDs referenced in source files
  while IFS= read -r src; do
    local rel_src="${src#./}"
    while IFS= read -r ref_id; do
      if ! jq -e --arg id "$ref_id" 'has($id)' "$REGISTRY" > /dev/null 2>&1; then
        echo "STALE: ${rel_src} references ${ref_id} (not in registry)" >&2
        exit_code=1
      fi
    done < <(grep -oE "$ID_PAT" "$src" 2>/dev/null | sort -u || true)
  done < <(
    find "$SRC_DIR" -name '*.rs' -type f 2>/dev/null | sort
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
