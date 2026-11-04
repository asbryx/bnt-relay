# COMMANDS - setup BNT mining (relay sendiri, alamat sendiri)

Ganti dulu tiga nilai ini:

- `<ALAMAT-BNT-KAMU>` - alamat wallet BNT kamu sendiri
- `<IP-A>` - IP publik VPS relay (mesin A)
- `<IP-EGRESS-B>` - IP egress mesin miner (dari `curl -s ifconfig.me` di mesin B)

## 0. Isi alamat kamu di skrip (sekali saja, sebelum setup miner)

Download `setup-complete.sh` dari repo ini. Baris `PRODUCTION_ADDRESS` sudah terisi alamat BNT pemilik repo; skrip menolak jalan untuk mode mining kalau baris itu kosong. Verifikasi dengan `grep PRODUCTION_ADDRESS setup-complete.sh`.

## 1. Mesin A (VPS relay, sebagai root)

```bash
cd /root
curl -fsSL -o setup-complete.sh https://raw.githubusercontent.com/asbryx/bnt-relay/main/setup-complete.sh
chmod +x setup-complete.sh
bash -n setup-complete.sh
./setup-complete.sh relay <IP-EGRESS-B>
systemctl status bnt-relay --no-pager
ss -ltnp | grep 443
```

Lulus kalau service `active`, ada listener di :443, dan iptables INPUT punya ACCEPT untuk IP egress B di port 443 sebelum DROP.

## 2. Mesin B (miner, sebagai root)

```bash
cd /root
curl -fsSL -o setup-complete.sh https://raw.githubusercontent.com/asbryx/bnt-relay/main/setup-complete.sh
chmod +x setup-complete.sh
bash -n setup-complete.sh
# pastikan PRODUCTION_ADDRESS di file ini sudah alamat BNT kamu
grep PRODUCTION_ADDRESS setup-complete.sh
./setup-complete.sh mining --relay <IP-A> --run
```

## 3. Verifikasi miner (mesin B)

```bash
cd /root/bnt-seine-runner
tail -n 50 bakekok.log
ps aux | grep '[s]eine'
grep HugePages /proc/meminfo
grep -E 'POOL_URL|ADDRESS' bakekok.sh
```

Lulus kalau:

- Log memuat `login accepted` dan share `accepted` mulai naik dalam puluhan detik.
- `POOL_URL` isinya `stratum+tcp://<IP-A>:443`.
- `ADDRESS` isinya alamat BNT kamu sendiri.
- `HugePages_Total` = 1024.

Saldo dan hashrate: buka My Stats di bntpool.com, tempel alamat BNT kamu.

## 4. Berhenti / jalan lagi

```bash
pkill -f seine            # berhenti
cd /root/bnt-seine-runner && nohup ./bakekok.sh > bakekok.log 2>&1 & disown   # jalan lagi
```

## Troubleshooting singkat

- Miner timeout ke relay: IP egress B belum masuk allowlist mesin A, atau relay belum listen. Cek dari B: `timeout 5 bash -c 'cat < /dev/null > /dev/tcp/<IP-A>/443 && echo OK'`.
- Miner putus-sambung terus: pastikan `relay.py` yang terpasang versi repo ini (ada perbaikan settimeout setelah connect).
- HugePages kurang dari 1024: RAM mesin B kurang longgar. Cek `free -h`, reboot mesin B, lalu jalan lagi.
- Share stale tinggi atau reconnect berulang dari relay: cek `journalctl -u bnt-relay -n 50` di mesin A.
