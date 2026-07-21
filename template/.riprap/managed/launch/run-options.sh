#!/bin/sh
# Validate a project's runtime options file and emit each accepted option on its own line.
#
# One option per line keeps the file free of shell quoting rules, so an option reaches the runtime
# exactly as written. A line is accepted only as a single whitespace-free argument beginning with
# "-". Checks run in a fixed order -- whitespace, then leading "-" -- so a line with both defects is
# reported identically by every launcher and every runtime.
#
# The options are whitespace-free by construction, so a caller reads the emitted lines back into a
# list by splitting on newlines alone. An absent file emits nothing and succeeds. On a rejected line
# the function writes an actionable diagnostic naming the file and line to stderr and returns 1;
# because callers invoke it in a command substitution, that nonzero return stops the launch before
# any container starts.
emit_run_options() {
    _rofile="$1"
    [ -f "$_rofile" ] || return 0
    _roline=0
    while IFS= read -r _raw || [ -n "$_raw" ]; do
        _roline=$((_roline + 1))
        # Remove only the terminal carriage return from a CRLF checkout. An embedded carriage
        # return remains content and is rejected by the whitespace check below.
        _opt="$(printf '%s' "$_raw" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$_opt" in
            ''|'#'*) continue ;;
        esac
        case "$_opt" in
            *[[:space:]]*)
                printf 'Riprap: %s line %s: an option must be a single argument with no spaces: %s\n' \
                    "$_rofile" "$_roline" "$_opt" >&2
                return 1 ;;
        esac
        case "$_opt" in
            -*) ;;
            *)
                printf "Riprap: %s line %s: an option must begin with '-': %s\n" \
                    "$_rofile" "$_roline" "$_opt" >&2
                return 1 ;;
        esac
        printf '%s\n' "$_opt"
    done < "$_rofile"
}

# A caller turns the emitted options into its own positional parameters with:
#
#     options="$(emit_run_options "$file")" || exit 1
#     set --
#     IFS='
#     '
#     for opt in $options; do set -- "$@" "$opt"; done
#     unset IFS
#
# splitting on newlines alone, which is safe because every emitted option is whitespace-free.
