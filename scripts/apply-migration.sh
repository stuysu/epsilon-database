#!/usr/bin/env bash
# Applies one migration file in a single transaction as supabase_admin and
# records it in public.schema_migrations.
#
#   scripts/apply-migration.sh [--dry-run] [--yes] 057_EXAMPLE.sql
#
# --dry-run  runs the file, then ROLLBACK (nothing is kept or recorded)
# --yes      skip the confirmation prompt for non-local targets
#
# Target (first match wins):
#   DATABASE_URL=postgres://supabase_admin:...@host:5432/postgres
#   DB_SSH=user@host DB_CONTAINER=supabase-db   (docker exec over ssh)
#   DB_CONTAINER=name                           (local docker, default supabase_db_localsb)
set -euo pipefail

dry_run=0
assume_yes=0
file=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --yes) assume_yes=1 ;;
        -*) echo "Unknown option $arg" >&2; exit 2 ;;
        *) file="$arg" ;;
    esac
done

if [[ -z "$file" || ! -f "$file" ]]; then
    echo "Usage: $0 [--dry-run] [--yes] NNN_NAME.sql" >&2
    exit 2
fi

name=$(basename "$file")
if [[ ! "$name" =~ ^([0-9]{3})_[A-Za-z0-9_]+\.sql$ ]]; then
    echo "File name must look like 057_SOME_NAME.sql" >&2
    exit 2
fi
version="${BASH_REMATCH[1]}"

container="${DB_CONTAINER:-supabase_db_localsb}"
psql_args=(-X -q -v ON_ERROR_STOP=1)
if [[ -n "${DATABASE_URL:-}" ]]; then
    target="DATABASE_URL host ${DATABASE_URL##*@}"
    run() { psql "$DATABASE_URL" "${psql_args[@]}"; }
    remote=1
elif [[ -n "${DB_SSH:-}" ]]; then
    target="$DB_SSH, container $container"
    run() { ssh "$DB_SSH" "docker exec -i $container psql -U supabase_admin -d postgres ${psql_args[*]}"; }
    remote=1
else
    target="local container $container"
    run() { docker exec -i "$container" psql -U supabase_admin -d postgres "${psql_args[@]}"; }
    remote=0
fi

# Enum values added before the file's BEGIN; are committed on their own first.
preamble=$("$(dirname "$0")/check-preamble.sh" "$file")

# The script owns the transaction, so drop the file's own BEGIN;/COMMIT; lines
# and refuse anything else that could end the transaction early.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
body=$(awk -v stray="$tmp" '
    BEGIN { tag = "" }
    {
        line = tolower($0)
        if (tag == "" && line ~ /^[ \t]*(begin|commit|start transaction)[ \t]*;[ \t]*(--.*)?$/) next
        if (tag == "" && line ~ /^[ \t]*(commit|rollback|abort|end|begin)([ \t]+(work|transaction))?[ \t]*;/) print NR ": " $0 > stray
        print
        s = $0
        while (match(s, /\$[A-Za-z_]*\$/)) {
            t = substr(s, RSTART, RLENGTH)
            if (tag == "") tag = t; else if (t == tag) tag = ""
            s = substr(s, RSTART + RLENGTH)
        }
    }' <(if [[ -n "$preamble" ]]; then awk -v part=rest -f "$(dirname "$0")/preamble.awk" "$file"; else cat "$file"; fi))
stray=$(cat "$tmp")
if [[ -n "$stray" ]]; then
    echo "Refusing: $name has transaction control the script can't wrap:" >&2
    echo "$stray" >&2
    exit 2
fi

applied_by="${APPLIED_BY:-$(git config user.name 2>/dev/null || echo "${USER:-unknown}")}"
applied_by="${applied_by//\'/\'\'}"

if [[ $dry_run -eq 1 ]]; then mode="DRY RUN"; finish="ROLLBACK;"; else mode="APPLY"; finish="COMMIT;"; fi
echo "$mode $name on $target"

if [[ $remote -eq 1 && $assume_yes -eq 0 && ( $dry_run -eq 0 || -n "$preamble" ) ]]; then
    [[ $dry_run -eq 1 ]] && echo "Even in a dry run, these are committed first (Postgres can't use a new enum value in the same transaction):" && echo "$preamble"
    read -r -p "Type the version ($version) to continue: " answer
    [[ "$answer" == "$version" ]] || { echo "Cancelled."; exit 1; }
fi

if [[ -n "$preamble" ]]; then
    echo "Committing enum values first:"
    echo "$preamble"
    run <<< "$preamble"
fi

run <<SQL
BEGIN;
SET LOCAL lock_timeout = '15s';
SELECT set_config('migration.version', '$version', true) \\g /dev/null
DO \$check\$
DECLARE v text := current_setting('migration.version');
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    IF v <> '057' THEN
      RAISE EXCEPTION 'public.schema_migrations is missing. Apply 057_AUDIT_FIXES.sql first.';
    END IF;
  ELSIF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = v) THEN
    RAISE EXCEPTION 'Migration % is already recorded in public.schema_migrations.', v;
  END IF;
END
\$check\$;

$body

INSERT INTO public.schema_migrations (version, name, applied_by)
VALUES ('$version', '$name', '$applied_by')
ON CONFLICT (version) DO UPDATE SET applied_by = EXCLUDED.applied_by;
$finish
SQL

if [[ $dry_run -eq 1 ]]; then
    echo "OK: $name ran cleanly and was rolled back."
else
    echo "OK: $name applied and recorded."
fi
