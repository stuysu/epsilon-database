#!/usr/bin/env bash
# If everything a migration runs before its first "BEGIN;" is an enum value
# addition, prints those statements; otherwise prints nothing. Postgres can't
# use a new enum value in the transaction that adds it, so they're committed
# first and the rest of the file runs after.
set -euo pipefail
pre=$(awk -v part=pre -f "$(dirname "$0")/preamble.awk" "$1" | sed -e 's/--.*$//' | tr '\n' ' ' | tr -s ' ')
pre="${pre# }"; pre="${pre% }"
[[ -z "$pre" ]] && exit 0
IFS=';' read -ra stmts <<< "$pre"
out=""
for s in "${stmts[@]}"; do
    s="${s# }"; s="${s% }"
    [[ -z "$s" ]] && continue
    shopt -s nocasematch
    if [[ ! "$s" =~ ^ALTER\ TYPE\ [A-Za-z0-9_.\"]+\ ADD\ VALUE\ IF\ NOT\ EXISTS\ \'[^\']+\'(\ (BEFORE|AFTER)\ \'[^\']+\')?$ ]]; then
        exit 0
    fi
    shopt -u nocasematch
    out+="$s;"$'\n'
done
printf '%s' "$out"
