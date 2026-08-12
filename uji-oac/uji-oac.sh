#!/usr/bin/env bash
#
# B4 — pembuktian penandatanganan Origin Access Control atas request BER-BODY.
#
# ARCHITECTURE.md §12.2 mewajibkan ini dilakukan pada hari pertama infrastruktur
# naik, lewat request sungguhan sejak API masih berupa stub — bukan ditemukan
# ketika frontend mulai menyimpan nilai.
#
# Menuntut image `:bootstrap` sedang terpasang pada fungsi `edutrack-api`, yaitu
# keadaan tepat sesudah `terraform apply` pada infra/ dan sebelum rilis pertama.
#
#   ./uji-oac.sh https://dxxxxxxxxxxxx.cloudfront.net
#
# Alamatnya diambil dari output Terraform:
#
#   terraform -chdir=infra output -raw domain_cloudfront

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Pemakaian: $0 <alamat-cloudfront>" >&2
  exit 2
fi

DASAR="${1%/}"
LULUS=0
GAGAL=0

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Memeriksa KEDUA sisi kontrak CK-A-12 sekaligus:
#
#   1. tanpa `x-amz-content-sha256` request WAJIB ditolak 403
#   2. dengan header itu request lolos, dan body sampai utuh
#
# Butir 1 sama pentingnya dengan butir 2. Kalau suatu hari ia mulai lolos, yang
# berubah adalah perilaku layanan AWS - dan CK-A-12 beserta pembungkus fetch di
# frontend perlu ditinjau ulang.
#
# Yang dibandingkan sidik jari, bukan panjang. Body yang dipotong tertangkap
# keduanya; body yang berubah isinya karena penyandian ulang hanya tertangkap
# sidik jari.
periksa() {
  local nama="$1" metode="$2" badan="$3"

  local harapan
  harapan=$(printf '%s' "$badan" | sha256)

  local tanpa
  tanpa=$(curl -sS -o /dev/null -w '%{http_code}' -X "$metode" "$DASAR/api/uji-body" \
    -H 'content-type: application/json' --data-binary "$badan" 2>/dev/null || echo "000")
  if [ "$tanpa" != "403" ]; then
    printf '  GAGAL  %-28s tanpa header dijawab %s, SEHARUSNYA 403 (CK-A-12)\n' "$nama" "$tanpa"
    GAGAL=$((GAGAL + 1))
    return
  fi

  local status isi
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X "$metode" "$DASAR/api/uji-body" \
    -H 'content-type: application/json' -H "x-amz-content-sha256: $harapan" \
    --data-binary "$badan" 2>/dev/null || echo "000")

  if [ "$status" != "200" ]; then
    printf '  GAGAL  %-28s dengan header dijawab %s\n' "$nama" "$status"
    if [ "$status" = "403" ]; then
      echo "         Sidik jari yang dikirim tidak cocok dengan body yang sampai,"
      echo "         atau izin lambda:InvokeFunction belum ada — DEPLOYMENT §5.2."
    fi
    GAGAL=$((GAGAL + 1))
    return
  fi

  isi=$(curl -sS -X "$metode" "$DASAR/api/uji-body" \
    -H 'content-type: application/json' -H "x-amz-content-sha256: $harapan" \
    --data-binary "$badan")

  local diterima panjang
  diterima=$(printf '%s' "$isi" | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p')
  panjang=$(printf '%s' "$isi" | sed -n 's/.*"panjang_diterima":\([0-9]*\).*/\1/p')

  if [ "$diterima" = "$harapan" ]; then
    printf '  LULUS  %-28s %s bita — tanpa header 403, dengan header cocok\n' "$nama" "$panjang"
    LULUS=$((LULUS + 1))
  else
    printf '  GAGAL  %-28s sidik jari BERBEDA\n' "$nama"
    printf '         dikirim   %s (%s bita)\n' "$harapan" "${#badan}"
    printf '         diterima  %s (%s bita)\n' "$diterima" "$panjang"
    GAGAL=$((GAGAL + 1))
  fi
}

echo "Pembuktian penandatanganan OAC — $DASAR"
echo

# --- 1. Jalur tanpa body harus tetap hidup ---------------------------------
#
# Diperiksa lebih dahulu supaya kegagalan pada uji berikutnya dapat dipastikan
# berasal dari body-nya, bukan dari OAC yang memang belum menyala sama sekali.
status_sehat=$(curl -sS -o /dev/null -w '%{http_code}' "$DASAR/api/healthz")
if [ "$status_sehat" = "200" ]; then
  printf '  LULUS  %-28s status 200\n' "GET /api/healthz"
  LULUS=$((LULUS + 1))
else
  printf '  GAGAL  %-28s status %s\n' "GET /api/healthz" "$status_sehat"
  echo "         Jalur tanpa body pun belum tembus. Hentikan di sini —"
  echo "         yang salah bukan penandatanganan body."
  exit 1
fi

# --- 2. Request ber-body ----------------------------------------------------

periksa "POST kecil" POST '{"nilai":88}'
periksa "PATCH kecil" PATCH '{"catatan":"baik"}'

# Simpan Nilai sekelas adalah request ber-body terbesar yang benar-benar ada:
# 30 siswa dikali 8 komponen, yaitu 240 nilai dalam satu transaksi
# (ARCHITECTURE.md §14.1). Ia diuji tersendiri karena batas ukuran yang
# menyebabkan pemotongan tidak pernah terlihat pada body kecil.
besar='{"nilai":['
for i in $(seq 1 240); do
  [ "$i" -gt 1 ] && besar="$besar,"
  besar="$besar{\"siswa_ref\":\"00000000-0000-4000-8000-$(printf '%012d' "$i")\",\"komponen_ref\":\"00000000-0000-4000-8000-000000000001\",\"nilai\":88.5}"
done
besar="$besar]}"

periksa "POST 240 nilai" POST "$besar"

# --- 3. Jalur yang TIDAK boleh tembus --------------------------------------
#
# Function URL beraut AWS_IAM hanya menerima request bertanda tangan SigV4 dari
# distribusi yang ditunjuk. Apabila alamatnya dapat dipanggil langsung, seluruh
# pemisahan pada ARCHITECTURE.md Pasal 2 tidak berlaku - dan tidak ada satu pun
# gejala yang menandainya.
if [ -n "${URL_FUNGSI:-}" ]; then
  langsung=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${URL_FUNGSI%/}/api/uji-body" \
    -H 'content-type: application/json' -d '{"nilai":88}' || echo "000")
  if [ "$langsung" = "403" ]; then
    printf '  LULUS  %-28s status 403 — Function URL menolak\n' "POST langsung tanpa OAC"
    LULUS=$((LULUS + 1))
  else
    printf '  GAGAL  %-28s status %s — SEHARUSNYA 403\n' "POST langsung tanpa OAC" "$langsung"
    GAGAL=$((GAGAL + 1))
  fi
else
  echo "  LEWAT  POST langsung tanpa OAC     setel URL_FUNGSI untuk mengujinya"
fi

echo
echo "Lulus $LULUS, gagal $GAGAL."
[ "$GAGAL" -eq 0 ]
