#!/usr/bin/env bash
# exposure-audit.sh: list what a self-hosted Pangolin publishes and whether
# each resource enforces auth. Read-only (opens the DB with -readonly).
#
# Usage:  sudo ./exposure-audit.sh [/path/to/pangolin/config/db/db.sqlite]
#         (with no argument it searches the local filesystem for the DB)
#
# Reading the output:
#   sso=1                      requests must pass Pangolin auth before reaching the app
#   sso=0/empty + no pass/PIN  resource is fully public; the app's own auth is all there is
#   ACCEPT rules               can bypass auth for matching paths/IPs, so review each one
#
# Pangolin's schema changes between versions. If a query fails, check the
# .tables output and adjust the table/column names.

set -u
command -v sqlite3 >/dev/null || { echo "sqlite3 is required"; exit 1; }

DB=${1:-$(find / -xdev -path '*config/db/db.sqlite' 2>/dev/null | head -1)}
[ -f "$DB" ] || { echo "Pangolin DB not found; pass its path as the first argument"; exit 1; }
echo "DB: $DB"
Q="sqlite3 -readonly -header -column $DB"

echo; echo "-- Tables (for schema troubleshooting)"
sqlite3 -readonly "$DB" ".tables"

echo; echo "-- Resources -> targets"
$Q "SELECT r.resourceId AS id, r.name, r.fullDomain, r.sso, t.ip, t.port, t.enabled
    FROM resources r LEFT JOIN targets t ON t.resourceId = r.resourceId
    ORDER BY r.name;"

echo; echo "-- Resources with no SSO, password or PIN (fully public)"
$Q "SELECT r.resourceId AS id, r.name, r.fullDomain FROM resources r
    WHERE COALESCE(r.sso,0) = 0
      AND r.resourceId NOT IN (SELECT resourceId FROM resourcePassword)
      AND r.resourceId NOT IN (SELECT resourceId FROM resourcePincode)
    ORDER BY r.name;"

echo; echo "-- Resources with password / PIN"
$Q "SELECT 'password' AS type, resourceId FROM resourcePassword
    UNION ALL SELECT 'pincode', resourceId FROM resourcePincode;"

echo; echo "-- Rules (ACCEPT can bypass auth)"
$Q "SELECT ru.ruleId, ru.resourceId, r.name, ru.enabled, ru.priority, ru.action, ru.match, ru.value
    FROM resourceRules ru LEFT JOIN resources r ON r.resourceId = ru.resourceId
    ORDER BY ru.resourceId, ru.priority;"
