#!/usr/bin/env bash
# setup-complete.sh — setup LENGKAP mining BNT + relay, dari nol.
#
# Satu skrip, dua peran (jalankan di mesin yang sesuai):
#   ./setup-complete.sh relay <IP-MINER> [IP-MINER...]
#       Pasang relay di mesin ini: relay.py + systemd + firewall
#       allowlist. Target relay: bntpool.com:3333 (pool lama).
#   ./setup-complete.sh mining [--direct | --relay IP-RELAY] [--run]
#       Pasang miner di mesin ini: Seine + bakekok.sh.
#       Default: lewat relay (perlu --relay IP-RELAY). Pakai
#       --direct hanya kalau direct ke bntpool terbukti jalan
#       dari mesin ini (dari ArkClaw direct terbukti kena RST).
#
# Alur lengkap yang dimaksud:
#   Mesin A (relay) : ./setup-complete.sh relay <IP-egress-Mesin-B>
#   Mesin B (miner) : ./setup-complete.sh mining --relay <IP-Mesin-A> --run
#   Verifikasi      : log miner harus "login accepted" + share accepted.
#
# Catatan alamat: bakekok.sh di-download dari repo bnt-seine-runner,
# lalu skrip ini MENULIS ULANG baris POOL_URL dan baris ADDRESS-nya
# ke alamat kamu di atas, lalu memverifikasi keduanya dengan grep
# sebelum miner dijalankan. Jadi ADDRESS hasil download yang sempat
# berbeda di satu Claw tidak akan lolos lagi.
set -euo pipefail

SEINE_VERSION="v0.2.45"
SEINE_SHA256="19e3c979d14f38664bdfb28c2b48e4b0580a1cb711bae2ee68bcbc9ea41bd173"
SEINE_URL_GITHUB="https://github.com/zpalmtree/seine/releases/download/${SEINE_VERSION}/seine-linux-x86_64.tar.gz"
# Sumber: rilis resmi GitHub (halaman rilis + API asset di bawah).
# Mirror jsDelivr lama hanya membawa tarball v0.2.21, jadi tidak dipakai lagi.
# Keaslian binary dijamin SHA-256 resmi di atas, selalu diverifikasi
# setelah download dan skrip berhenti kalau tidak cocok.
SEINE_URL_API="https://api.github.com/repos/zpalmtree/seine/releases/assets/686138695"
# Alamat wallet BNT MILIK SENDIRI (fork asbryx/bnt-relay).
# Skrip ini MENULIS alamat ini ke bakekok.sh saat setup mining.
# WAJIB diisi alamat BNT kamu sendiri sebelum mining dijalankan.
# Kosong = skrip berhenti (guard di cmd_mining).
PRODUCTION_ADDRESS="MDbQ7pxgrybvAXKUZYwQKMCBE4L5GJkeJvsiVhjTsvAW1mP5qorsf3VCNS3GdXuDQgJLBdPPhPyXTWN9VCLYeEL2GdRZQ"
BAKEKOK_URL_JSDELIVR="https://cdn.jsdelivr.net/gh/asbryx/bnt-relay@main/bakekok.sh"
BAKEKOK_URL_RAW="https://raw.githubusercontent.com/asbryx/bnt-relay/main/bakekok.sh"
RELAY_URL_JSDELIVR="https://cdn.jsdelivr.net/gh/asbryx/bnt-relay@main/relay.py"
RELAY_URL_RAW="https://raw.githubusercontent.com/asbryx/bnt-relay/main/relay.py"
SERVICE_URL_JSDELIVR="https://cdn.jsdelivr.net/gh/asbryx/bnt-relay@main/bnt-relay.service"
SERVICE_URL_RAW="https://raw.githubusercontent.com/asbryx/bnt-relay/main/bnt-relay.service"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "jalankan sebagai root"; }

# Download dengan fallback berurutan; argumen: output, url1, url2, ...
download() {
    local out="$1"; shift
    local url
    for url in "$@"; do
        echo "Mencoba download: $url"
        hdr=()
        [[ "$url" == *"api.github.com"* ]] && hdr=(-H "Accept: application/octet-stream")
        if curl -L --connect-timeout 15 --max-time 300 "${hdr[@]}" "$url" -o "$out"; then
            if [ -s "$out" ]; then
                echo "OK: $out"
                return 0
            fi
        fi
        echo "Gagal / kosong: $url"
        rm -f "$out"
    done
    return 1
}

usage() {
    cat <<'EOF'
Pakai:
  ./setup-complete.sh relay <IP-MINER> [IP-MINER...]
  ./setup-complete.sh mining --relay <IP-RELAY> [--run]
  ./setup-complete.sh mining --direct [--run]
  ./setup-complete.sh mining --pool <URL-STRATUM> [--run]

Contoh lengkap:
  # di mesin relay (A), izinkan miner B:
  ./setup-complete.sh relay 203.0.113.10
  # di mesin miner (B), mining lewat relay A, langsung jalan:
  ./setup-complete.sh mining --relay 198.51.100.20 --run
EOF
    exit 1
}

cmd_relay() {
    need_root
    [ "$#" -ge 1 ] || { echo "ERROR: relay butuh minimal 1 IP miner." >&2; usage; }
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    echo "== 1. Pasang relay.py =="
    mkdir -p /opt/bnt-relay
    if [ -f "$script_dir/relay.py" ] && grep -q 'TARGET_HOST = "bntpool.com"' "$script_dir/relay.py"; then
        cp "$script_dir/relay.py" /opt/bnt-relay/relay.py
        echo "relay.py disalin dari folder skrip."
    fi
    cd /opt/bnt-relay
    if [ -f relay.py ] && grep -q 'TARGET_HOST = "bntpool.com"' relay.py 2>/dev/null; then
        echo "relay.py sudah ada di folder ini, dipakai apa adanya."
    else
        download relay.py "$RELAY_URL_JSDELIVR" "$RELAY_URL_RAW" \
            || die "tidak bisa download relay.py dari semua mirror"
    fi
    grep -q 'TARGET_HOST = "bntpool.com"' relay.py \
        || die "relay.py target-nya bukan bntpool, berhenti"
    python3 -m py_compile relay.py
    echo "== 2. Pasang service systemd =="
    if [ -f "$script_dir/bnt-relay.service" ]; then
        cp "$script_dir/bnt-relay.service" /etc/systemd/system/bnt-relay.service
    elif [ -f bnt-relay.service ]; then
        cp bnt-relay.service /etc/systemd/system/bnt-relay.service
    else
        download /etc/systemd/system/bnt-relay.service \
            "$SERVICE_URL_JSDELIVR" "$SERVICE_URL_RAW" \
            || die "tidak bisa download bnt-relay.service"
    fi
    systemctl daemon-reload
    systemctl enable --now bnt-relay
    echo "== 3. Firewall allowlist (ACCEPT dulu, baru DROP) =="
    for ip in "$@"; do
        if iptables -C INPUT -s "$ip/32" -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
            echo "Sudah ada: $ip"
        else
            iptables -I INPUT -s "$ip/32" -p tcp --dport 443 -j ACCEPT
            echo "Ditambahkan: $ip"
        fi
    done
    if ! iptables -C INPUT -p tcp --dport 443 -j DROP 2>/dev/null; then
        iptables -A INPUT -p tcp --dport 443 -j DROP
    fi
    mkdir -p /etc/iptables
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4
        echo "Aturan disimpan ke /etc/iptables/rules.v4"
    else
        echo "PERINGATAN: iptables-save tidak ada, aturan belum persisten."
    fi
    echo "== 4. Verifikasi relay =="
    systemctl is-active bnt-relay
    ss -ltnp 2>/dev/null | grep ':443' || echo "PERINGATAN: tidak terlihat listener :443"
    iptables -S INPUT | grep -- '--dport 443' || true
    echo "SELESAI (relay). Lanjut: di mesin miner jalankan mining --relay <IP-mesin-ini>."
}

cmd_mining() {
    need_root
    [ -n "$PRODUCTION_ADDRESS" ] || die "PRODUCTION_ADDRESS masih kosong. Isi dulu alamat BNT kamu sendiri di setup-complete.sh baris PRODUCTION_ADDRESS."
    local mode="" relay_ip="" run_miner=0 pool_override=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pool) pool_override="${2:-}"; [ -n "$pool_override" ] || die "--pool butuh URL stratum"; shift 2 ;;
            --relay) relay_ip="${2:-}"; [ -n "$relay_ip" ] || die "--relay butuh IP"; shift 2 ;;
            --direct) mode="direct"; shift ;;
            --run) run_miner=1; shift ;;
            *) die "argumen tidak dikenal: $1 (lihat usage)" ;;
        esac
    done
    local pool_url
    if [ -n "$pool_override" ]; then
        pool_url="$pool_override"
    elif [ -n "$relay_ip" ]; then
        pool_url="stratum+tcp://${relay_ip}:443"
    elif [ "$mode" = "direct" ]; then
        pool_url="stratum+tcp://bntpool.com:3333"
    else
        die "pilih salah satu: --pool <URL> atau --relay <IP-RELAY> atau --direct"
    fi
    echo "== 1. Folder + binary Seine ${SEINE_VERSION} =="
    mkdir -p /root/bnt-seine-runner
    cd /root/bnt-seine-runner
    installed_version=""
    if [ -x ./seine ]; then
        installed_version="$(./seine --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
    fi
    if [ -n "$installed_version" ] && [ "$installed_version" = "${SEINE_VERSION#v}" ]; then
        echo "Binary ./seine sudah versi ${SEINE_VERSION}, download dilewati."
    else
        if [ -n "$installed_version" ]; then
            echo "Binary ./seine lama (v${installed_version}) ditemukan, diganti ke ${SEINE_VERSION}."
        fi
        download seine.tar.gz "$SEINE_URL_GITHUB" "$SEINE_URL_API" \
            || die "tidak bisa download seine.tar.gz dari semua mirror"
        echo "${SEINE_SHA256}  seine.tar.gz" | sha256sum -c - \
            || die "SHA-256 seine.tar.gz tidak cocok, berhenti (file corrupt / bukan rilis resmi)"
        tar -xzf seine.tar.gz
        chmod +x ./seine
        ./seine --version
    fi
    echo "== 2. Download bakekok.sh (POOL_URL + ADDRESS ditulis skrip ini) =="
    download bakekok.sh "$BAKEKOK_URL_JSDELIVR" "$BAKEKOK_URL_RAW" \
        || die "tidak bisa download bakekok.sh dari semua mirror"
    chmod +x bakekok.sh
    cp bakekok.sh "bakekok.sh.orig-$(date +%Y%m%d%H%M%S)"
    sed -i "s|stratum+tcp://[^'\"]*|${pool_url}|" bakekok.sh
    # Tulis alamat kamu langsung, jangan percaya ADDRESS hasil download.
    sed -i "s|^ADDRESS=.*|ADDRESS=${PRODUCTION_ADDRESS}|" bakekok.sh
    grep POOL_URL bakekok.sh
    grep -q "POOL_URL='${pool_url}'" bakekok.sh \
        || die "POOL_URL gagal diubah ke ${pool_url}, berhenti"
    grep -q "ADDRESS=${PRODUCTION_ADDRESS}" bakekok.sh \
        || die "ADDRESS gagal ditulis ke alamat kamu, berhenti"
    grep ADDRESS bakekok.sh
    bash -n bakekok.sh
    ls -lh ./seine bakekok.sh
    echo "SELESAI (miner siap). Pool: ${pool_url}"
    echo "ADDRESS sudah ditulis skrip ini ke alamat kamu di atas."
    echo "Pastikan PRODUCTION_ADDRESS di skrip adalah alamat BNT kamu sendiri sebelum --run."
    if [ "$run_miner" = "1" ]; then
        echo "== 3. Jalankan miner =="
        nohup ./bakekok.sh > bakekok.log 2>&1 &
        disown
        sleep 15
        tail -n 40 bakekok.log
        grep HugePages /proc/meminfo || true
        echo "Cari di log: 'login accepted' + share 'accepted'. Kalau HugePages <1024, lihat README bagian troubleshooting."
    else
        echo "Jalankan miner dengan:"
        echo "  cd /root/bnt-seine-runner && nohup ./bakekok.sh > bakekok.log 2>&1 & disown && sleep 15 && tail -n 40 bakekok.log"
    fi
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
    relay) cmd_relay "$@" ;;
    mining) cmd_mining "$@" ;;
    *) usage ;;
esac
