#!/usr/bin/env bash
# patch-runtimes.sh: upgrade the PHP and Node.js runtimes that runtime-check.sh
# flags, on Proxmox LXCs and on this host. For Kubernetes pods and Docker
# containers it reports which workload or stack to bump, because those are
# fixed by pulling a new image, not by patching in place.
#
# DRY RUN BY DEFAULT. Nothing changes unless you pass --apply.
#
# Usage:
#   sudo ./patch-runtimes.sh                      # plan for every running LXC
#   sudo ./patch-runtimes.sh 133 200 201          # plan for these LXCs only
#   sudo ./patch-runtimes.sh --apply 200          # snapshot, upgrade, restart, re-check
#   sudo ./patch-runtimes.sh --host               # this machine instead of LXCs
#   sudo ./patch-runtimes.sh --k8s                # which deployments need a new image
#   sudo ./patch-runtimes.sh --docker             # which compose stacks need a pull
#
# Options:
#   --apply         actually upgrade (default is a dry run)
#   --no-snapshot   don't take a pct snapshot first (LXCs only; default takes one)
#   --no-restart    upgrade packages but don't restart the services using them
#   --restart-only  skip upgrades; restart services still running an old (deleted)
#                   node/php binary, e.g. after an upgrade done some other way
#
# What it can fix automatically: runtimes installed from an apt or apk package
# (NodeSource, Debian/Ubuntu PHP, sury.org, Alpine). Anything else (nvm, a
# tarball in /usr/local or /opt, a binary bundled with an app) is listed as
# MANUAL with its path so you know where it came from.
#
# Exit: 0 = nothing left below its floor, 1 = something still needs attention.

set -u

# Keep in sync with runtime-check.sh.
FLOORS="${FLOORS:-php:8.2.35 php:8.3.36 php:8.4.27 php:8.5.12 node:22.23.4 node:24.22.1 node:26.12.1}"

APPLY=0 SNAP=1 RESTART=1 MODE=lxc RONLY=0
TARGETS=()
for a in "$@"; do
  case $a in
    --apply) APPLY=1 ;;
    --no-snapshot) SNAP=0 ;;
    --no-restart) RESTART=0 ;;
    --restart-only) RONLY=1 ;;
    --host) MODE=host ;;
    --k8s) MODE=k8s ;;
    --docker) MODE=docker ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    [0-9]*) TARGETS+=("$a") ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

LEFT=0   # runtimes still below the floor at the end

verdict() { # $1=runtime $2=version -> ok | VULNERABLE (<floor) | EOL
  local rt=$1 v=${2#v} f
  for e in $FLOORS; do
    [ "${e%%:*}" = "$rt" ] || continue
    f=${e#*:}
    if [ "$rt" = php ]; then
      [ "${f%.*}" = "$(echo "$v" | cut -d. -f1-2)" ] || continue
    else
      [ "${f%%.*}" = "${v%%.*}" ] || continue
    fi
    if [ "$(printf '%s\n%s\n' "$f" "$v" | sort -V | head -1)" = "$f" ]; then echo ok
    else echo "VULNERABLE (<$f)"; fi
    return
  done
  echo "EOL (no fix on this branch)"
}

# ---------------------------------------------------------------- probes
# All run inside the target with plain sh, so they work on Debian and Alpine.

# "php X.Y.Z" / "node vX.Y.Z"
PROBE='for b in php php85 php84 php83 php82 php81; do
  command -v $b >/dev/null 2>&1 && { echo "php $($b -r "echo PHP_VERSION;")"; break; }
done
command -v node >/dev/null 2>&1 && echo "node $(node -v)"
exit 0'

# "pm apt|apk|none", then "own <rt> <package|-> <real path>" per runtime
DETECT='pm=none
command -v apt-get >/dev/null 2>&1 && pm=apt
command -v apk >/dev/null 2>&1 && pm=apk
echo "pm $pm"
for rt in php node; do
  bin=
  if [ $rt = php ]; then
    for b in php php85 php84 php83 php82 php81; do
      command -v $b >/dev/null 2>&1 && { bin=$(command -v $b); break; }
    done
  else
    bin=$(command -v node 2>/dev/null)
  fi
  [ -n "$bin" ] || continue
  real=$(readlink -f "$bin")
  own=
  case $pm in
    apt) own=$(dpkg -S "$real" 2>/dev/null | head -1 | cut -d: -f1) ;;
    apk) own=$(apk info --who-owns "$real" 2>/dev/null | sed "s/.* //; s/-[0-9].*//") ;;
  esac
  echo "own $rt ${own:--} $real"
done
exit 0'

# Upgrade. Expects PM, DO_NODE, DO_PHP set in front of it.
UPGRADE='set -e
if [ "$PM" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  pk=
  [ "$DO_NODE" = 1 ] && pk="$pk nodejs"
  [ "$DO_PHP" = 1 ] && pk="$pk $(dpkg-query -W -f="\${db:Status-Abbrev} \${Package}\n" "php*" 2>/dev/null | awk "/^ii/{print \$2}" | tr "\n" " ")"
  apt-get update -qq -o DPkg::Lock::Timeout=180 || true
  apt-get install -y -qq --only-upgrade -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold $pk
elif [ "$PM" = apk ]; then
  pk=
  [ "$DO_NODE" = 1 ] && pk="$pk nodejs"
  [ "$DO_PHP" = 1 ] && pk="$pk $(apk info 2>/dev/null | grep -E "^php[0-9]*(-|$)" | tr "\n" " ")"
  apk update -q
  apk upgrade -q $pk
fi'

# Restart whatever is still running the old binary. After a package upgrade,
# a process that started before it shows "(deleted)" on its exe (node, php-fpm)
# or on a mapped libphp (Apache mod_php). Only those get restarted.
# Expects DRY=0|1 set in front of it.
RESTARTS='if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  echo "  no systemd here: restart the PHP/Node services yourself, or reboot the container"
  exit 0
fi
units=
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  e=$(readlink "$d/exe" 2>/dev/null) || continue
  hit=
  case $e in
    *"/node (deleted)"|*"/nodejs (deleted)"|*"/php-fpm"*" (deleted)") hit=1 ;;
  esac
  [ -z "$hit" ] && grep -q "libphp.* (deleted)" "$d/maps" 2>/dev/null && hit=1
  [ -n "$hit" ] || continue
  u=$(ps -o unit= -p "$p" 2>/dev/null | tr -d " ")
  case $u in
    user@*.service|*.scope|""|-)
      echo "  pid $p ($(cat "$d/comm" 2>/dev/null)) is on the old binary outside a system service ($u): restart it yourself" ;;
    *.service) units="$units $u" ;;
  esac
done
units=$(echo $units | tr " " "\n" | sort -u)
if [ -z "$units" ]; then
  echo "  no system services running the old binary"
  exit 0
fi
for u in $units; do
  if [ "$DRY" = 1 ]; then echo "  would restart $u"
  else systemctl restart "$u" && echo "  restarted $u" || echo "  FAILED to restart $u"; fi
done
exit 0'

# ---------------------------------------------------------------- helpers
run_in() { # $1 = host | <ctid>, $2 = sh script
  if [ "$1" = host ]; then sh -c "$2" </dev/null
  else pct exec "$1" -- sh -c "$2" </dev/null; fi
}

show() { # $1=label; reads probe output, prints rows, returns 1 if any flagged
  local bad=0 rt v st
  while read -r rt v; do
    st=$(verdict "$rt" "$v")
    printf '  %-5s %-9s %s\n' "$rt" "$v" "$st"
    [ "$st" = ok ] || bad=1
  done < <(grep -E '^(php|node) v?[0-9]')
  return $bad
}

patch_target() { # $1 = host | <ctid>
  local t=$1 label probe flagged pm line rt own path do_node=0 do_php=0 manual=0
  [ "$t" = host ] && label="host $(hostname)" || label="lxc $t"

  probe=$(run_in "$t" "$PROBE" 2>/dev/null)
  flagged=$(echo "$probe" | grep -E '^(php|node) v?[0-9]' | while read -r rt v; do
    [ "$(verdict "$rt" "$v")" = ok ] || echo "$rt"; done)
  [ -n "$flagged" ] || return 0

  echo
  echo "== $label"
  echo "$probe" | show "$label" || true

  pm=none
  while read -r line; do
    set -- $line
    case $1 in
      pm) pm=$2 ;;
      own)
        rt=$2 own=$3 path=$4
        echo "$flagged" | grep -qx "$rt" || continue
        case $path in
          */.nvm/*|/usr/local/*|/opt/*|/root/*|/home/*) own=- ;;
        esac
        if [ "$own" = - ] || [ "$pm" = none ]; then
          echo "  MANUAL  $rt at $path (not from a package; update it the way it was installed)"
          manual=1
        else
          echo "  plan    upgrade $rt via $pm (package: $own)"
          [ "$rt" = node ] && do_node=1
          [ "$rt" = php ] && do_php=1
        fi ;;
    esac
  done < <(run_in "$t" "$DETECT" 2>/dev/null)

  if [ $do_node = 0 ] && [ $do_php = 0 ]; then
    LEFT=$((LEFT + $(echo "$flagged" | wc -l))); return 0
  fi
  if [ $APPLY = 0 ]; then
    echo "  (dry run: re-run with --apply to do it)"
    LEFT=$((LEFT + $(echo "$flagged" | wc -l))); return 0
  fi

  if [ "$t" != host ] && [ $SNAP = 1 ]; then
    local snap="prepatch_$(date +%Y%m%d_%H%M)"
    if pct snapshot "$t" "$snap" >/dev/null 2>&1; then
      echo "  snapshot $snap taken (roll back: pct rollback $t $snap)"
    else
      echo "  SKIPPED: snapshot failed (storage may not support it). Use --no-snapshot to go ahead anyway."
      LEFT=$((LEFT + $(echo "$flagged" | wc -l))); return 0
    fi
  fi

  echo "  upgrading..."
  if ! run_in "$t" "PM=$pm DO_NODE=$do_node DO_PHP=$do_php; $UPGRADE" >/tmp/patch-runtimes.$$.log 2>&1; then
    echo "  UPGRADE FAILED. Last lines:"; tail -5 /tmp/patch-runtimes.$$.log | sed 's/^/    /'
  fi
  rm -f /tmp/patch-runtimes.$$.log
  [ $RESTART = 1 ] && run_in "$t" "DRY=0; $RESTARTS"

  echo "  after:"
  probe=$(run_in "$t" "$PROBE" 2>/dev/null)
  if ! echo "$probe" | show "$label"; then
    local n; n=$(echo "$probe" | grep -E '^(php|node) v?[0-9]' | while read -r rt v; do
      [ "$(verdict "$rt" "$v")" = ok ] || echo x; done | wc -l)
    LEFT=$((LEFT + n))
    echo "  still below the floor: the package repo may not have the fix yet, or the distro"
    echo "  backports fixes without changing the version (check the package changelog for the CVE)"
  fi
  return 0
}

# ---------------------------------------------------------------- modes
case $MODE in
lxc)
  command -v pct >/dev/null 2>&1 || { echo "pct not found: run this on the Proxmox host, or use --host" >&2; exit 2; }
  if [ ${#TARGETS[@]} -eq 0 ]; then
    mapfile -t TARGETS < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')
  fi
  [ $APPLY = 1 ] && echo "APPLY mode: snapshot=$SNAP restart=$RESTART" || echo "DRY RUN (nothing will change)"
  if [ $RONLY = 1 ]; then
    for ct in "${TARGETS[@]}"; do echo "== lxc $ct"; run_in "$ct" "DRY=$((1-APPLY)); $RESTARTS"; done
    exit 0
  fi
  for ct in "${TARGETS[@]}"; do patch_target "$ct"; done
  ;;
host)
  [ $APPLY = 1 ] && echo "APPLY mode on this host: restart=$RESTART" || echo "DRY RUN (nothing will change)"
  if [ $RONLY = 1 ]; then echo "== host $(hostname)"; run_in host "DRY=$((1-APPLY)); $RESTARTS"; exit 0; fi
  patch_target host
  ;;
k8s)
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 2; }
  echo "Pods are fixed by bumping the image tag in your manifests or GitOps repo."
  echo "Patching inside a pod doesn't survive a restart, and ArgoCD would revert a live edit."
  printf '\n%-40s %-6s %-9s %-20s %s\n' WORKLOAD RT VERSION STATUS IMAGE
  kubectl get pods -A --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' |
  while read -r ns p; do
    out=$(timeout 15 kubectl exec -n "$ns" "$p" -- sh -c "$PROBE" 2>/dev/null </dev/null)
    echo "$out" | grep -E '^(php|node) v?[0-9]' | while read -r rt v; do
      st=$(verdict "$rt" "$v"); [ "$st" = ok ] && continue
      kind=$(kubectl get pod -n "$ns" "$p" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
      own=$(kubectl get pod -n "$ns" "$p" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
      if [ "$kind" = ReplicaSet ]; then
        own=$(kubectl get rs -n "$ns" "$own" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "$own")
        kind=Deployment
      fi
      img=$(kubectl get pod -n "$ns" "$p" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
      printf '%-40s %-6s %-9s %-20s %s\n' "$ns/${kind:-Pod}/${own:-$p}" "$rt" "$v" "$st" "$img"
      echo x >> /tmp/patch-runtimes-left.$$
    done
  done
  [ -f /tmp/patch-runtimes-left.$$ ] && LEFT=$(wc -l < /tmp/patch-runtimes-left.$$) && rm -f /tmp/patch-runtimes-left.$$
  ;;
docker)
  command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 2; }
  echo "Containers are fixed by pulling a newer image and recreating them"
  echo "(docker compose pull && docker compose up -d in the stack's folder, or through Arcane/Portainer)."
  printf '\n%-28s %-6s %-9s %-20s %-18s %s\n' CONTAINER RT VERSION STATUS STACK IMAGE
  docker ps --format '{{.Names}}' | while read -r c; do
    out=$({ docker exec "$c" sh -c "$PROBE" 2>/dev/null </dev/null || docker exec "$c" node -v 2>/dev/null </dev/null | sed 's/^/node /'; })
    echo "$out" | grep -E '^(php|node) v?[0-9]' | while read -r rt v; do
      st=$(verdict "$rt" "$v"); [ "$st" = ok ] && continue
      stack=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)
      img=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)
      printf '%-28s %-6s %-9s %-20s %-18s %s\n' "$c" "$rt" "$v" "$st" "${stack:--}" "$img"
      echo x >> /tmp/patch-runtimes-left.$$
    done
  done
  [ -f /tmp/patch-runtimes-left.$$ ] && LEFT=$(wc -l < /tmp/patch-runtimes-left.$$) && rm -f /tmp/patch-runtimes-left.$$
  ;;
esac

echo
if [ "$LEFT" -gt 0 ]; then
  echo "$LEFT runtime(s) still need attention"
  exit 1
fi
echo "Nothing left below its floor"
