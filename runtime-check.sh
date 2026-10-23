#!/usr/bin/env bash
# runtime-check.sh — find PHP and Node.js runtimes on this host, its Docker
# containers, Proxmox LXCs and Kubernetes pods, and flag anything below the
# patched floor for its branch. Skips whatever this host doesn't have
# (docker / pct / kubectl), so the same script runs everywhere.
#
# Usage:   sudo ./runtime-check.sh
#          FLOORS="php:8.4.30 node:24.23.0" ./runtime-check.sh   # override floors
#
# Exit:    0 = everything at or above its floor
#          1 = at least one runtime VULNERABLE or on an EOL branch
#
# Read-only: it only runs `php -r 'echo PHP_VERSION;'` and `node -v` inside targets.

set -u

# runtime:minimum-patched-version, one entry per supported branch.
# A runtime whose branch has no entry is reported as EOL.
#   PHP2Shell, CVE-2026-109618 / CVE-2026-109619 (21 Oct 2026)
#   Node.js October 2026 security release, incl. CVE-2026-111497 (21 Oct 2026)
FLOORS="${FLOORS:-php:8.2.35 php:8.3.36 php:8.4.27 php:8.5.12 node:22.23.4 node:24.22.1 node:26.12.1}"

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

verdict() { # $1=runtime $2=version
  local rt=$1 v=${2#v} f branch
  for e in $FLOORS; do
    [ "${e%%:*}" = "$rt" ] || continue
    f=${e#*:}
    if [ "$rt" = php ]; then            # PHP branches are major.minor
      branch=$(echo "$v" | cut -d. -f1-2); [ "${f%.*}" = "$branch" ] || continue
    else                                # Node branches are major
      [ "${f%%.*}" = "${v%%.*}" ] || continue
    fi
    if [ "$(printf '%s\n%s\n' "$f" "$v" | sort -V | head -1)" = "$f" ]; then
      echo "ok"
    else
      echo "VULNERABLE (<$f)"
    fi
    return
  done
  echo "EOL (no fix on this branch)"
}

# Runs inside each target; prints "php X.Y.Z" and/or "node vX.Y.Z"
PROBE='for b in php php85 php84 php83 php82 php81; do
  command -v $b >/dev/null 2>&1 && { echo "php $($b -r "echo PHP_VERSION;")"; break; }
done
command -v node >/dev/null 2>&1 && echo "node $(node -v)"
exit 0'

report() { # $1=kind $2=location; reads probe output on stdin
  grep -E '^(php|node) v?[0-9]' | while read -r rt v; do
    printf '%-7s %-48s %-5s %-9s %s\n' "$1" "$2" "$rt" "$v" "$(verdict "$rt" "$v")" | tee -a "$OUT"
  done
}

# Fallback for images with no shell (distroless Node etc.)
bare_node() { # $@ = exec prefix
  local v
  v=$("$@" node -v 2>/dev/null || "$@" /nodejs/bin/node -v 2>/dev/null) && echo "node $v"
}

printf '%-7s %-48s %-5s %-9s %s\n' KIND LOCATION RT VERSION STATUS

# Host
sh -c "$PROBE" 2>/dev/null | report host "$(hostname)"
# Ubuntu/RHEL backport fixes without bumping PHP's version number, so distro
# PHP flagged here may already be fixed: check the package changelog.
if grep -qE '^host .* php .*VULNERABLE' "$OUT" && dpkg-query -W -f='${Version}' 'php*-common' 2>/dev/null | grep -q ubuntu; then
  echo "  note: host PHP is Ubuntu-packaged; confirm with: zgrep -E 'CVE-2026-10961[89]' /usr/share/doc/php*-common/changelog.Debian.gz"
fi

# Docker
if command -v docker >/dev/null 2>&1; then
  docker ps --format '{{.Names}}' 2>/dev/null | while read -r c; do
    { docker exec "$c" sh -c "$PROBE" 2>/dev/null </dev/null || bare_node docker exec "$c" </dev/null; } | report docker "$c"
  done
fi

# Proxmox LXCs (container rootfs only; Docker running inside an LXC needs
# the script run inside that LXC)
if command -v pct >/dev/null 2>&1; then
  pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | while read -r ct; do
    pct exec "$ct" -- sh -c "$PROBE" 2>/dev/null </dev/null | report lxc "$ct"
  done
fi

# Kubernetes (default container of each running pod)
if command -v kubectl >/dev/null 2>&1 && kubectl get ns >/dev/null 2>&1; then
  kubectl get pods -A --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' |
  while read -r ns p; do
    { timeout 15 kubectl exec -n "$ns" "$p" -- sh -c "$PROBE" 2>/dev/null </dev/null \
        || bare_node timeout 15 kubectl exec -n "$ns" "$p" -- </dev/null; } | report pod "$ns/$p"
  done
fi

echo
if grep -qE 'VULNERABLE|EOL' "$OUT"; then
  echo "FAIL: $(grep -cE 'VULNERABLE|EOL' "$OUT") runtime(s) need attention"
  exit 1
fi
echo "OK: no vulnerable runtimes found"
