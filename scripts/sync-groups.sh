#!/usr/bin/env bash
# sync-groups.sh — make Google Group club-leaders@stuysu.org match the Supabase club DB.
#
# What it does:
#   Reads the live Supabase DB (everyone who is ADMIN or CREATOR of a club),
#   then syncs club-leaders@stuysu.org to match exactly.
#   Sync = adds new leaders, removes anyone the DB no longer lists.
#   usersonly: only USER members are synced; nested GROUP members
#   (e.g. executive@stuysu.org) are left alone — the DB only knows people.
#   OWNER/MANAGER members (the human admins) are not touched by role=member sync.
#   Only membership changes; the group itself is never touched. Safe to re-run.
#
# Usage:
#   ./sync-groups.sh                     show this help
#   ./sync-groups.sh --auth <admin@stuysu.org> [user@stuysu.org]
#                                        one-time Google authentication
#   ./sync-groups.sh --dry-run           preview adds/removes, changes NOTHING
#   ./sync-groups.sh --run               apply the changes
#
# Authentication (one-time, headless box — links open on your laptop):
#   ./sync-groups.sh --auth <your-admin@stuysu.org>
#   runs, in order:
#     1. gam create project <admin>     skipped if already created
#     2. gam oauth create <admin>       prints URL + code; open URL elsewhere, paste code back
#     3. gam user <user> check serviceaccount
#          prints scopes -> add them in Google Admin console, wait, re-run until PASS
#          (<user> defaults to the admin address if omitted)
#   Verify: gam show admin   (no "No Client Access" allowed error)
#
# Requires: docker supabase-db container up, GAM at /root/bin/gam7/gam.
set -euo pipefail

GAM=/root/bin/gam7/gam
PSQL="docker exec -i supabase-db psql -U supabase_admin -h 127.0.0.1 -Atc"
GROUP=club-leaders@stuysu.org

authed() { "$GAM" show admin >/dev/null 2>&1; }

need_auth() {
  echo "Not authenticated with Google yet." >&2
  echo "Run:  $0 --auth <your-admin@stuysu.org>" >&2
  echo "(full steps are in: $0 --help)" >&2
  exit 1
}

do_auth() {
  local admin="${1:-}" user="${2:-$1}"
  [ -n "$admin" ] || { echo "Usage: $0 --auth <admin@stuysu.org> [user@stuysu.org]" >&2; exit 2; }
  "$GAM" config no_browser true save
  echo "== 1/3 create project ($admin)"
  if [ -f /root/.gam/oauth2service.json ]; then
    echo "   service account already exists — skipping (project created)"
  else
    "$GAM" create project "$admin"
  fi
  echo "== 2/3 admin oauth ($admin)"
  "$GAM" oauth create "$admin"
  echo "== 3/3 service account scopes ($user)"
  echo "   (expected to fail first time — paste the printed scopes into the"
  echo "    Google Admin console, wait a few minutes, then re-run this)"
  "$GAM" user "$user" check serviceaccount || {
    echo "Scopes not PASSing yet. Add them in the admin console, wait, re-run:" >&2
    echo "  $0 --auth $admin $user" >&2
    exit 1
  }
  echo "Auth complete. Verify with: $0 --dry-run"
}

sql() { $PSQL "$1"; }

case "${1:-}" in
  --auth)  do_auth "${2:-}" "${3:-}"; exit $? ;;
  --run|--dry-run) authed || need_auth ;;
  -h|--help|"")
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) echo "Unknown arg: $1 (try --dry-run, --run, --auth, or --help)" >&2; exit 2 ;;
esac

DRY=false; [[ "$1" == "--dry-run" ]] && DRY=true

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Desired leadership from the DB
sql "select distinct u.email from public.memberships m join public.users u on u.id=m.user_id where m.role in ('ADMIN','CREATOR') and m.active = true order by 1" > "$tmp/leaders.txt"
[ -s "$tmp/leaders.txt" ] || { echo "ABORT: leadership query returned no rows — refusing to empty the group" >&2; exit 1; }
[ "$(wc -l < "$tmp/leaders.txt")" -ge 300 ] || { echo "ABORT: leadership query returned fewer than 300 rows, refusing to sync" >&2; exit 1; }

# GAM prints "Remove (Preview) 1 Member" (singular) or "… 437 Members",
# and detail "…, Removed (Preview)" with "(n/N)" only when count > 1.
# Match both forms — an earlier regex requiring plural silently showed no changes.
if $DRY; then
  echo "== $GROUP: $(wc -l < "$tmp/leaders.txt") desired leaders — preview (nothing changes):"
  if ! "$GAM" update group "$GROUP" sync member usersonly preview file "$tmp/leaders.txt" >"$tmp/prev.out" 2>&1; then
    echo "ERROR: preview failed" >&2
    sed 's/^/    /' "$tmp/prev.out" >&2
    exit 1
  fi
  if ! grep -qE "\(Preview\) [1-9][0-9]* Members?$" "$tmp/prev.out"; then
    echo "  no changes — group already matches the DB"
  else
    grep -E ", (Add|Remove) \(Preview\) [0-9]+ Members?$" "$tmp/prev.out" | sed 's/^Group: /  /'
    echo "  leaders to add:"
    n=$(grep -c ", Added (Preview)" "$tmp/prev.out" || true)
    if [ "$n" -gt 0 ]; then
      grep ", Added (Preview)" "$tmp/prev.out" | sed -E 's/.*Member: ([^,]+),.*/    + \1/'
    else
      echo "    (none)"
    fi
    echo "  members to remove:"
    n=$(grep -c ", Removed (Preview)" "$tmp/prev.out" || true)
    if [ "$n" -gt 0 ]; then
      grep ", Removed (Preview)" "$tmp/prev.out" | sed -E 's/.*Member: ([^,]+),.*/    - \1/' | sed -n '1,15p'
      [ "$n" -gt 15 ] && echo "    ... and $((n-15)) more"
    else
      echo "    (none)"
    fi
  fi
else
  echo "== $GROUP: syncing $(wc -l < "$tmp/leaders.txt") leaders"
  if ! "$GAM" redirect csv "$tmp/action.csv" update group "$GROUP" sync member usersonly actioncsv file "$tmp/leaders.txt" >"$tmp/run.out" 2>&1; then
    echo "ERROR: sync failed" >&2
    sed 's/^/    /' "$tmp/run.out" >&2
    exit 1
  fi
  # Keep the last results and GAM's own summary so the counts below can be checked.
  cp "$tmp/action.csv" /var/log/sync-groups-last.csv 2>/dev/null || echo "WARN: no results file from GAM" >&2
  grep -E "(Add|Remove) [0-9]+ Members?$" "$tmp/run.out" | sed 's/^Group: /  /' || true
  added=$(grep -c ",Added," "$tmp/action.csv" 2>/dev/null || true)
  removed=$(grep -c ",Removed," "$tmp/action.csv" 2>/dev/null || true)
  failed=$(grep -ci "fail" "$tmp/action.csv" 2>/dev/null || true)
  echo "  added: ${added:-0}  removed: ${removed:-0}  failed: ${failed:-0}"
  if [ "${failed:-0}" -gt 0 ]; then
    echo "WARN: failed entries:" >&2
    grep -i "fail" "$tmp/action.csv" >&2
    exit 1
  fi
fi
echo "Done."
