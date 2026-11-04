#!/usr/bin/env bash
#
# bnt_miner.sh — Blocknet (BNT) miner installer for bntpool.com
#
# Usage:
#   DRYRUN=1 sh bnt_miner.sh        Audit only. Nothing is written, downloaded,
#                                   started, or changed. Read-only checks only.
#   sh bnt_miner.sh                 Install and start the miner.
#   sh bnt_miner.sh status          Show service state, recent logs, hugepages.
#   sh bnt_miner.sh uninstall       Stop, disable, remove unit, files, sysctl.
#
# Operator constraints this script follows:
#   1. Payout goes to the operator's own BNT wallet. The address is validated
#      by recomputing its checksum before anything is installed.
#   2. The miner binary is the official zpalmtree/seine GitHub release. Its
#      SHA-256 is checked twice: against the release's own SHA256SUMS.txt,
#      and against a pinned known-good digest. A mismatch aborts before
#      extraction.
#   3. Direct connection to bntpool.com:3333. No relay, no port 443, no proxy.
#   4. Persistence is systemd only (Restart=always). No cron, no silent
#      watchdog, no supervisor script. Logs go to journald.
#   5. Uninstall removes the unit, the runner directory and the hugepage
#      reservation, and releases the reserved pages.
#
set -euo pipefail

# ---------------------------------------------------------------- constants --

SEINE_VERSION="v0.3.0"
SEINE_ASSET="seine-linux-x86_64.tar.gz"
SEINE_RELEASE="https://github.com/zpalmtree/seine/releases/download/${SEINE_VERSION}"
SEINE_TARBALL="${SEINE_RELEASE}/${SEINE_ASSET}"
SEINE_SUMS="${SEINE_RELEASE}/SHA256SUMS.txt"

# Known-good digest for seine-linux-x86_64.tar.gz at v0.3.0. Cross-checked
# against the release manifest and the GitHub API asset digest (asset id
# 700808761). If the release ever changes, this must change with it.
SEINE_SHA256="5e4fb99d03181816443614d97b9e09354270b41696f440491dfac570ff59c586"

PAYOUT_ADDRESS="MDbQ7pxgrybvAXKUZYwQKMCBE4L5GJkeJvsiVhjTsvAW1mP5qorsf3VCNS3GdXuDQgJLBdPPhPyXTWN9VCLYeEL2GdRZQ"
POOL_URL="stratum+tcp://bntpool.com:3333"

RUN_DIR="/root/bnt-seine-runner"
SERVICE_NAME="bnt-miner"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-seine-hugepages.conf"
HUGEPAGES="1024"          # 1024 x 2 MiB = 2 GiB, one Argon2id arena

DRYRUN="${DRYRUN:-0}"
TMP_DIR=""

# ------------------------------------------------------------------ helpers --

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

# Run a command, or only print it in dry-run mode.
do_cmd() {
    if [ "$DRYRUN" = "1" ]; then
        printf '[DRYRUN] would run: %s\n' "$*"
    else
        printf '+ %s\n' "$*"
        "$@"
    fi
}

# Write stdin to a file, or only print it in dry-run mode.
do_write() {
    local path="$1"
    if [ "$DRYRUN" = "1" ]; then
        printf '[DRYRUN] would write %s:\n' "$path"
        cat
        printf '[DRYRUN] --- end of %s ---\n' "$path"
    else
        printf '+ writing %s\n' "$path"
        cat > "$path"
    fi
}

# Download a URL to a file, or only print it in dry-run mode.
fetch() {
    local url="$1" out="$2"
    if [ "$DRYRUN" = "1" ]; then
        printf '[DRYRUN] would download %s\n' "$url"
        return 0
    fi
    printf '+ curl %s\n' "$url"
    curl -fsSL --connect-timeout 15 --max-time 300 "$url" -o "$out" \
        || die "download failed: $url"
}

# ------------------------------------------------------- address validation --

# Blocknet addresses are base58(spendPub[32] || viewPub[32] || checksum[4]).
# The checksum is SHA3-256("blocknet_stealth_address_checksum" ||
# "blocknet_mainnet" || spendPub || viewPub)[:4]. Base58 is case-sensitive, so
# a single wrong-case character decodes to a completely different keypair and
# fails here. This runs before anything is installed.
verify_payout_address() {
    step "Payout address validation"
    say "address: ${PAYOUT_ADDRESS}"
    local out
    if ! out=$(python3 - "$PAYOUT_ADDRESS" <<'PYEOF'
import hashlib, sys
A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
def b58d(s):
    n = 0
    for c in s:
        n = n * 58 + A.index(c)
    pad = len(s) - len(s.lstrip('1'))
    return b'\x00' * pad + n.to_bytes((n.bit_length() + 7) // 8, 'big')
addr = sys.argv[1]
try:
    raw = b58d(addr)
except Exception:
    sys.exit("not valid base58")
if len(raw) != 68:
    sys.exit("decodes to %d bytes, expected 68" % len(raw))
ck = hashlib.sha3_256(
    b'blocknet_stealth_address_checksum' + b'blocknet_mainnet' + raw[:64]
).digest()[:4]
if ck != raw[64:68]:
    sys.exit("CHECKSUM INVALID: stored %s, computed %s"
             % (raw[64:68].hex(), ck.hex()))
print("  checksum VALID")
print("  spendPub: %s" % raw[:32].hex())
print("  viewPub : %s" % raw[32:64].hex())
PYEOF
    ); then
        printf '%s\n' "$out" >&2
        die "payout address failed validation — refusing to install"
    fi
    printf '%s\n' "$out"
}

# ------------------------------------------------------------- diagnostics ---

diagnose() {
    step "Environment diagnostics (read-only)"
    say "user  : $(id -un) (uid $(id -u))"
    say "kernel: $(uname -r)"
    say ""
    say "--- memory ---"
    free -m 2>/dev/null || say "(free not available)"
    say ""
    say "--- hugepages ---"
    grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo 2>/dev/null \
        || say "(/proc/meminfo not readable)"
    say ""
    say "--- top memory consumers ---"
    ps aux --sort=-%mem 2>/dev/null | head -n 10 \
        || ps aux 2>/dev/null | head -n 10 \
        || say "(ps not available)"
    say ""
    say "--- existing miner ---"
    if [ -x "${RUN_DIR}/seine" ]; then
        say "found ${RUN_DIR}/seine"
        "${RUN_DIR}/seine" --version 2>/dev/null || say "(version query failed)"
    else
        say "no seine binary at ${RUN_DIR}/seine"
    fi
    say ""
    say "--- service state ---"
    if [ -f "$SERVICE_FILE" ]; then
        say "unit present: ${SERVICE_FILE}"
        say "enabled: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
        say "active : $(systemctl is-active  "$SERVICE_NAME" 2>/dev/null || echo unknown)"
    else
        say "no unit at ${SERVICE_FILE}"
    fi
    say ""
    say "--- pool reachability (direct, no relay) ---"
    if timeout 5 bash -c 'cat < /dev/null > /dev/tcp/bntpool.com/3333' 2>/dev/null; then
        say "bntpool.com:3333 reachable"
    else
        say "bntpool.com:3333 NOT reachable — mining will not connect"
    fi
}

# ----------------------------------------------------------------- install ---

install_seine() {
    step "Installing Seine ${SEINE_VERSION}"

    if [ "$DRYRUN" = "1" ]; then
        printf '[DRYRUN] would download %s\n' "$SEINE_SUMS"
        printf '[DRYRUN] would verify the %s digest against that manifest\n' "$SEINE_ASSET"
        printf '[DRYRUN] would verify it against the pinned digest %s\n' "$SEINE_SHA256"
        printf '[DRYRUN] would download %s\n' "$SEINE_TARBALL"
        printf '[DRYRUN] would verify sha256, then extract into %s\n' "$RUN_DIR"
        return 0
    fi

    TMP_DIR=$(mktemp -d)

    fetch "$SEINE_SUMS" "$TMP_DIR/SHA256SUMS.txt"

    local expected
    expected=$(awk -v f="$SEINE_ASSET" '$2==f {print $1; exit}' "$TMP_DIR/SHA256SUMS.txt")
    [ -n "$expected" ] || die "asset ${SEINE_ASSET} not listed in the release manifest"
    [ "$expected" = "$SEINE_SHA256" ] \
        || die "manifest digest ${expected} does not match pinned ${SEINE_SHA256}"
    say "manifest digest matches pinned digest: ${expected}"

    fetch "$SEINE_TARBALL" "$TMP_DIR/${SEINE_ASSET}"

    printf '+ verifying sha256 of %s\n' "$SEINE_ASSET"
    echo "${expected}  ${TMP_DIR}/${SEINE_ASSET}" | sha256sum -c - \
        || die "tarball sha256 mismatch — aborting before extraction"

    mkdir -p "$RUN_DIR"
    tar -xzf "$TMP_DIR/${SEINE_ASSET}" -C "$RUN_DIR"
    chmod +x "${RUN_DIR}/seine"
    say "installed: $("${RUN_DIR}/seine" --version 2>&1 | head -n1)"
}

reserve_hugepages() {
    step "Hugepage reservation"
    say "target: ${HUGEPAGES} pages x 2 MiB = $((HUGEPAGES * 2)) MiB"
    say "(one 2 GiB Argon2id arena per hashing thread)"

    do_write "$SYSCTL_FILE" <<EOF
# Reserved for the Blocknet Seine miner (Argon2id, 2 GiB arena per thread).
# Claimed early at boot so other services cannot fragment the memory first.
vm.nr_hugepages = ${HUGEPAGES}
EOF

    if [ "$DRYRUN" = "1" ]; then
        printf '[DRYRUN] would run: sync; echo 3 > /proc/sys/vm/drop_caches\n'
        printf '[DRYRUN] would run: echo 1 > /proc/sys/vm/compact_memory\n'
        printf '[DRYRUN] would run: sysctl -w vm.nr_hugepages=%s\n' "$HUGEPAGES"
        printf '[DRYRUN] would then verify HugePages_Total >= %s\n' "$HUGEPAGES"
        return 0
    fi

    sysctl -w "vm.nr_hugepages=${HUGEPAGES}" >/dev/null 2>&1 || true
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    sysctl -w "vm.nr_hugepages=${HUGEPAGES}" >/dev/null 2>&1 || true

    local total
    total=$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)
    say "HugePages_Total=${total}"
    if [ "${total:-0}" -lt "$HUGEPAGES" ]; then
        say "WARNING: only ${total} of ${HUGEPAGES} pages reserved."
        say "The sysctl file is in place, so a reboot should claim them early."
        say "The miner still runs, but on regular pages, which is slower."
    fi
}

install_service() {
    step "Installing systemd unit"

    do_write "$SERVICE_FILE" <<EOF
[Unit]
Description=Blocknet (BNT) Seine Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${RUN_DIR}
ExecStartPre=/bin/sh -c 'echo ${HUGEPAGES} > /proc/sys/vm/nr_hugepages 2>/dev/null || true'
ExecStart=${RUN_DIR}/seine --pool-url ${POOL_URL} --address ${PAYOUT_ADDRESS} --no-auto-update --ui plain
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    do_cmd systemctl daemon-reload
    do_cmd systemctl enable "$SERVICE_NAME"
    do_cmd systemctl restart "$SERVICE_NAME"
}

report() {
    step "Installed"
    say "service : ${SERVICE_NAME}"
    say "pool    : ${POOL_URL}  (direct, no relay)"
    say "payout  : ${PAYOUT_ADDRESS}"
    say "binary  : ${RUN_DIR}/seine"
    say "logs    : journalctl -u ${SERVICE_NAME} -f"
    say "status  : sh bnt_miner.sh status"
    say "remove  : sh bnt_miner.sh uninstall"
    say ""

    if [ "$DRYRUN" = "1" ]; then
        say "[DRYRUN] nothing was changed. Re-run without DRYRUN to install."
        return 0
    fi

    say "waiting 25s for the first log lines..."
    sleep 25
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
}

# --------------------------------------------------------- status/uninstall --

cmd_status() {
    step "Service status"
    systemctl status "$SERVICE_NAME" --no-pager || true
    step "Recent journald log"
    journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
    step "Hugepages"
    grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo || true
}

cmd_uninstall() {
    step "Uninstalling"
    do_cmd systemctl stop "$SERVICE_NAME" || say "(service was not running)"
    do_cmd systemctl disable "$SERVICE_NAME" || say "(service was not enabled)"

    if [ "$DRYRUN" = "1" ]; then
        printf '[DRYRUN] would remove %s\n' "$SERVICE_FILE"
        printf '[DRYRUN] would remove %s\n' "$RUN_DIR"
        printf '[DRYRUN] would remove %s\n' "$SYSCTL_FILE"
        printf '[DRYRUN] would release hugepages (vm.nr_hugepages=0)\n'
    else
        rm -f "$SERVICE_FILE"
        rm -rf "$RUN_DIR"
        rm -f "$SYSCTL_FILE"
        sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
        say "removed unit, runner directory, sysctl file; hugepages released"
    fi

    do_cmd systemctl daemon-reload
    say "uninstall complete"
}

# --------------------------------------------------------------------- main --

main() {
    local action="${1:-install}"
    case "$action" in
        install)
            verify_payout_address
            diagnose
            install_seine
            reserve_hugepages
            install_service
            report
            ;;
        status)    cmd_status ;;
        uninstall) cmd_uninstall ;;
        *) die "unknown action: ${action} (use install, status, or uninstall)" ;;
    esac
}

main "$@"
