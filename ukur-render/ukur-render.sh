#!/usr/bin/env bash
#
# B7 — pengukuran lama render tiga puluh PDF di dalam fungsi Lambda.
#
# API.md §13.3 menuntut satu angka: lama render tiga puluh PDF pdfmake
# berurutan BESERTA unggahannya ke S3, di dalam fungsi Lambda 1024 MB arm64.
# Pembanding lokalnya 431 ms — bukan angka Lambda.
#
# Yang diukur adalah jalur yang sesungguhnya, yaitu finalisasi sekelas. Tidak
# ada jalur pengukur tersendiri, karena jalur itu bukan kode produksi.
#
# Prosedur lengkap beserta cara membacanya: README.md di direktori ini.

set -euo pipefail

: "${ALAMAT:?setel ALAMAT, misalnya https://dxxxx.cloudfront.net}"
: "${KUKI:?setel KUKI berisi cookie sesi Wali Kelas}"
: "${KELAS_REF:?setel KELAS_REF berisi uuid kelas berisi 30 siswa}"

GRUP_LOG="${GRUP_LOG:-/aws/lambda/edutrack-api}"
DASAR="${ALAMAT%/}"

echo "Pengukuran render — $DASAR"
echo "Kelas $KELAS_REF"
echo

# Penanda waktu diambil SEBELUM request, dan dipakai membatasi pencarian log.
# Tanpa batas bawah, laporan invocation yang terbaca bisa saja milik request
# lain yang kebetulan berjalan berdekatan.
MULAI_MS=$(($(date +%s) * 1000 - 5000))

echo "Memfinalisasi..."
LAMA=$(curl -sS -o jawaban-finalisasi.json -w '%{time_total}' \
  -X POST "$DASAR/api/kelas/$KELAS_REF/rapor/finalisasi" \
  -H "cookie: $KUKI" -H 'content-type: application/json' -d '{}')

STATUS=$(jq -r 'if has("kesalahan") then .kesalahan.kode else "OK" end' jawaban-finalisasi.json)

if [ "$STATUS" != "OK" ]; then
  echo "GAGAL — $STATUS"
  jq . jawaban-finalisasi.json
  echo
  echo "Finalisasi yang ditolak tidak mengukur apa pun. Periksa prasyarat 3 pada"
  echo "README: seluruh nilai dan presensi wajib lengkap (I-20, AC-07)."
  exit 1
fi

TERENDER=$(jq -r '.data.berkas_terender // "?"' jawaban-finalisasi.json)

echo
echo "  Lama request (klien)   ${LAMA} detik"
echo "  berkas_terender        ${TERENDER} dari 30"
echo

# Laporan invocation memuat Duration, Init Duration, dan Max Memory Used pada
# satu baris. Log tidak segera tersedia; CloudWatch lazim tertinggal beberapa
# detik di belakang.
echo "Menunggu laporan invocation dari CloudWatch..."
for percobaan in 1 2 3 4 5 6; do
  sleep 10

  LAPORAN=$(aws logs filter-log-events \
    --log-group-name "$GRUP_LOG" \
    --start-time "$MULAI_MS" \
    --filter-pattern '"REPORT RequestId"' \
    --query 'events[-1].message' --output text 2>/dev/null || echo "None")

  if [ "$LAPORAN" != "None" ] && [ -n "$LAPORAN" ]; then
    echo
    echo "$LAPORAN" | tr '\t' '\n' | sed 's/^/  /'
    echo
    echo "Angka §13.3 adalah Duration di atas. Bandingkan dengan anggaran lunak"
    echo "20 detik, dan perhatikan pula jaraknya terhadap batas keras 30 detik."
    exit 0
  fi

  echo "  percobaan $percobaan — belum ada"
done

echo
echo "Laporan invocation tidak ditemukan dalam 60 detik."
echo "Periksa grup log: $GRUP_LOG"
exit 1
