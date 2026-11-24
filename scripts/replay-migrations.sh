#!/usr/bin/env bash
# Replays every numbered migration, in order, on an EMPTY throwaway database,
# then loads POPULATE_DATABASE.sql. Used by CI; also handy locally:
#
#   docker run -d --name epsilon-replay -e POSTGRES_PASSWORD=postgres supabase/postgres:17.11.0.004
#   DB_CONTAINER=epsilon-replay scripts/replay-migrations.sh
#   docker rm -f epsilon-replay
#
# Connection: DATABASE_URL (psql URL, connect as supabase_admin) or DB_CONTAINER.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${DATABASE_URL:-}" ]]; then
    psql_cmd=(psql "$DATABASE_URL")
elif [[ -n "${DB_CONTAINER:-}" ]]; then
    psql_cmd=(docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres)
else
    echo "Set DATABASE_URL or DB_CONTAINER to a throwaway database." >&2
    exit 2
fi

dupes=$(printf "%s\n" [0-9][0-9][0-9]_*.sql | cut -c1-3 | uniq -d)
if [[ -n "$dupes" ]]; then
    echo "Migration numbers used more than once: $dupes" >&2
    exit 1
fi

run() { "${psql_cmd[@]}" -X -q -v ON_ERROR_STOP=1 "$@"; }
# Enum values added before a file's BEGIN; must be committed before the rest.
apply() {
    local pre
    pre=$(scripts/check-preamble.sh "$1") || return 1
    if [[ -n "$pre" ]]; then
        run <<< "$pre" > /dev/null || return 1
    fi
    { echo "SET client_min_messages = error;"; if [[ -n "$pre" ]]; then awk -v part=rest -f scripts/preamble.awk "$1"; else cat "$1"; fi; } | run --single-transaction > /dev/null
}

tables=$(run -Atc "select count(*) from pg_tables where schemaname = 'public'")
if [[ "$tables" != "0" ]]; then
    echo "Refusing: public schema already has $tables tables. Use an empty database." >&2
    exit 2
fi

apply scripts/replay-bootstrap.sql

failed=0
for file in [0-9][0-9][0-9]_*.sql; do
    if apply "$file"; then
        echo "ok   $file"
    else
        echo "FAIL $file"
        failed=1
        break
    fi
done

if [[ $failed -eq 0 ]]; then
    if apply POPULATE_DATABASE.sql; then
        echo "ok   POPULATE_DATABASE.sql"
    else
        echo "FAIL POPULATE_DATABASE.sql"
        failed=1
    fi
fi

exit $failed
