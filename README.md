# php-node-runtime-check

Find every PHP and Node.js runtime across a homelab or small fleet (host, Docker containers, Proxmox LXCs, Kubernetes pods) and flag anything below the patched version for its branch. Includes Wazuh detection rules for PHP2Shell and a read-only Pangolin exposure audit.

Built during the response to **PHP2Shell** (CVE-2026-109618 / CVE-2026-109619) and the **Node.js October 2026 security release** (CVE-2026-111497 and others), both on 21 October 2026.

## Why runtime checks instead of image scanning

PHP and Node live *inside* container images, so `apt upgrade` on the host fixes nothing, and image names can't be trusted: a pastebin app built on PHP may have no "php" anywhere in its image name. Scanner databases also lag on brand-new CVEs. So this script asks each running thing directly: `php -r 'echo PHP_VERSION;'` and `node -v`.

## What's here

| Path | What it does |
|---|---|
| `runtime-check.sh` | Inventory + verdict for PHP and Node on host, Docker, LXCs, k8s pods. Exit 1 on findings. |
| `wazuh/rules/php2shell.xml` | Manager rules: webshell file drops, OOM/crash bursts, web-user command execution |
| `wazuh/agent-snippets.xml` | Agent config for those rules (FIM, logs, auditd); replace the placeholder paths |
| `auditd/webshell.rules` | auditd rule that logs commands run by the web server user |
| `pangolin/exposure-audit.sh` | Lists what a self-hosted [Pangolin](https://github.com/fosrl/pangolin) publishes and which resources have no auth |
| `examples/sample-output.txt` | Example run (made-up hosts) |

## Usage

```bash
curl -fsSLO https://raw.githubusercontent.com/goodelyfe/php-node-runtime-check/main/runtime-check.sh
less runtime-check.sh        # read before you run
sudo bash runtime-check.sh
```

Run it on each machine: a Docker host checks its containers, a Proxmox host checks its LXCs, and anywhere with a working `kubectl` checks the cluster. Sections for tools that aren't present are skipped.

Status meanings:

- **ok**: at or above the fixed version for that branch
- **VULNERABLE**: supported branch, below the fix. Pull/patch/rebuild.
- **EOL**: no fix exists for that branch (e.g. PHP ≤ 8.1, Node 20 and 25). Move to a supported major.

Note that Ubuntu and RHEL backport fixes into old version numbers (Ubuntu 24.04's PHP still says `8.3.6`), so distro PHP on a host may show VULNERABLE while actually patched. The script prints how to confirm via the package changelog.

## Updating for the next CVE

Everything is driven by one line:

```bash
FLOORS="php:8.2.35 php:8.3.36 php:8.4.27 php:8.5.12 node:22.23.4 node:24.22.1 node:26.12.1"
```

One `runtime:version` entry per supported branch. Edit it, or override at run time:

```bash
FLOORS="php:8.4.30 php:8.5.15 node:24.23.0" sudo -E bash runtime-check.sh
```

Because it exits non-zero on findings, it drops straight into a scheduled CI job (cron in Forgejo/GitHub Actions running it over SSH) to alert you when something falls behind.

## Wazuh rules

Rule IDs `100500`–`100503` are in the custom range; renumber if they clash. The OOM/crash rule fires on legitimate events now and then, which is why only the burst rule (5 in 2 minutes) is high severity. Run it for a day before wiring up push alerts.

## Limitations

- Kubernetes: checks the default container of each pod, not sidecars.
- LXCs: checks the LXC's own filesystem. Docker inside an LXC needs the script run inside that LXC.
- Shell-less images: Node is detected via a fallback; PHP in a shell-less image is not.
- It tells you versions, not exposure. Pair it with knowing what's reachable from the internet (see `pangolin/`).

## License

MIT
