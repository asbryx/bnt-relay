#!/usr/bin/env bash
set -Eeuo pipefail

# Seine runner for an already-downloaded Linux x86-64 binary.
# Place this script in the same directory as ./seine.
# This script does NOT download or extract anything.

POOL_URL='stratum+tcp://YOUR_RELAY_IP:443'
ADDRESS=MDbQ7pxgrybvAXKUZYwQKMCBE4L5GJkeJvsiVhjTsvAW1mP5qorsf3VCNS3GdXuDQgJLBdPPhPyXTWN9VCLYeEL2GdRZQ

# Seine reports a minimum of 1024 pages, each 2 MiB = 2 GiB total.
HUGEPAGES_TARGET=1024
HUGEPAGES_REQUIRED=1024
SYSCTL_CONF='/etc/sysctl.d/99-seine-hugepages.conf'

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Persist /etc/sysctl.d settings and adjust vm.nr_hugepages require root.
if [[ "${EUID}" -ne 0 ]]; then
  die 'Run as root, for example: sudo ./bakekok.sh'
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MINER="${SCRIPT_DIR}/seine"

[[ -f "$MINER" ]] || die "Cannot find the existing Seine binary at: $MINER. Put bakekok.sh beside ./seine."
if [[ ! -x "$MINER" ]]; then
  log 'seine is not executable; adding execute permission.'
  chmod +x "$MINER" || die 'Could not make seine executable.'
fi

# Read HugeTLB values from /proc/meminfo without relying on localized command output.
huge_total() { awk '/^HugePages_Total:/ {print $2}' /proc/meminfo; }
huge_free()  { awk '/^HugePages_Free:/  {print $2}' /proc/meminfo; }
huge_size()  { awk '/^Hugepagesize:/    {print $2}' /proc/meminfo; }
mem_avail()  { awk '/^MemAvailable:/    {print $2}' /proc/meminfo; }

page_size="$(huge_size)"
[[ "$page_size" == '2048' ]] || die "Expected 2048 kB HugeTLB pages, but system reports ${page_size:-unknown} kB."

log "Saving HugeTLB target: ${HUGEPAGES_TARGET} pages x 2 MiB = 2 GiB."
mkdir -p "$(dirname "$SYSCTL_CONF")"
tmp_conf="$(mktemp)"
trap '[[ -z "${tmp_conf:-}" ]] || rm -f -- "$tmp_conf"' EXIT
cat > "$tmp_conf" <<CONF
# Seine CPU miner HugeTLB pages
# 1024 x 2 MiB = 2 GiB; allocation may still depend on RAM availability at boot.
vm.nr_hugepages = ${HUGEPAGES_TARGET}
CONF
install -o root -g root -m 0644 "$tmp_conf" "$SYSCTL_CONF"
rm -f "$tmp_conf"
tmp_conf=''
log "Persistent setting written to $SYSCTL_CONF"

current_total="$(huge_total)"
current_free="$(huge_free)"

# If enough pages are already free (as after a successful manual reservation),
# don't disturb the current pool. Otherwise compact memory and retry allocation.
if (( current_free < HUGEPAGES_REQUIRED )); then
  log "Huge pages currently: total=${current_total}, free=${current_free}; trying memory compaction."
  echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || log 'Warning: memory compaction was unavailable.'

  for attempt in 1 2 3; do
    log "Requesting ${HUGEPAGES_TARGET} huge pages (attempt ${attempt}/3)."
    if sysctl -w "vm.nr_hugepages=${HUGEPAGES_TARGET}"; then
      sleep 2
    else
      log 'Warning: sysctl could not set vm.nr_hugepages.'
    fi

    current_total="$(huge_total)"
    current_free="$(huge_free)"
    if (( current_free >= HUGEPAGES_REQUIRED )); then
      break
    fi

    if (( attempt < 3 )); then
      echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
      sleep 2
    fi
  done
else
  log "Enough huge pages are already free (${current_free}); leaving the active pool unchanged."
fi

current_total="$(huge_total)"
current_free="$(huge_free)"
available_kb="$(mem_avail)"
log "HugePages_Total=${current_total}; HugePages_Free=${current_free}; Hugepagesize=${page_size} kB; MemAvailable=${available_kb} kB."

if (( current_free < HUGEPAGES_REQUIRED )); then
  die "Only ${current_free} HugeTLB pages are free; Seine needs at least ${HUGEPAGES_REQUIRED}. Not starting the miner. The sysctl setting remains saved; consider rebooting or checking VPS memory/boot settings."
fi

log 'HugeTLB check passed. Starting Seine.'
log "Pool: ${POOL_URL}"
log "Payout address: ${ADDRESS}"
log 'Press Ctrl+C to stop mining.'

# Run the miner in the foreground so logs are visible and Ctrl+C stops it.
exec "$MINER" --pool-url "$POOL_URL" --address "$ADDRESS"