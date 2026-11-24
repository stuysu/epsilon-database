# Splits a migration at its first top-level "BEGIN;" line (see check-preamble.sh).
#   awk -v part=pre  -f scripts/preamble.awk FILE   # lines before it
#   awk -v part=rest -f scripts/preamble.awk FILE   # that line and the rest
# Files without such a line have no preamble.
FNR == 1 { found = 0 }
!found && tolower($0) ~ /^[ \t]*begin[ \t]*;[ \t]*(--.*)?$/ { found = 1 }
{ if (found) rest[++nr] = $0; else pre[++np] = $0 }
END {
    if (!found) { if (part == "rest") for (i = 1; i <= np; i++) print pre[i]; exit }
    if (part == "pre") for (i = 1; i <= np; i++) print pre[i]
    else for (i = 1; i <= nr; i++) print rest[i]
}
