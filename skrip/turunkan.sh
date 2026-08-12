#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Membongkar seluruh lingkungan EduTrack di AWS — DEPLOYMENT.md CK-D-09.
#
# Akun ini ditagih per jam atas sumber daya yang berdiri, dan pembuatannya
# sendiri tidak berbiaya. Lingkungan yang menganggur karenanya lebih murah
# dibongkar daripada dibiarkan hidup.
#
#   ./skrip/turunkan.sh              cadangkan bila berubah, lalu bongkar
#   ./skrip/turunkan.sh --paksa      dump ulang meski sidiknya sama
#   ./skrip/turunkan.sh --tanpa-dump lewati pencadangan seluruhnya
#
# Yang sengaja TIDAK ikut dihapus, dan ketiganya berbiaya nol: OIDC provider
# GitHub (ia data source, bukan milik Terraform — memulihkannya menuntut konsol
# AWS), user `Andreas`, grup `Edutrack-dev`, dan role `edutrack-terraform`.
# ---------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=lib-sesi.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sesi.sh"

PAKSA=0
DUMP=1
for arg in "$@"; do
  case "$arg" in
  --paksa) PAKSA=1 ;;
  --tanpa-dump) DUMP=0 ;;
  *) galat "Argumen tidak dikenal: $arg" ;;
  esac
done

PATCH="$AKAR/skrip/izinkan-hapus.patch"
PATCH_TERPASANG=0
TMP=""

# Satu titik pembersihan bagi ketiga jalur keluar — selesai, galat, dan Ctrl-C.
# Inilah yang membuat pencabutan patch tidak bergantung pada skrip berjalan
# sampai habis.
bersihkan() {
  local kode=$?
  tutup_tunnel
  [[ -n $TMP ]] && rm -rf "$TMP"
  if ((PATCH_TERPASANG)); then
    git -C "$AKAR" checkout -- bootstrap/main.tf infra/data.tf infra/penyajian.tf 2>/dev/null || true
    PATCH_TERPASANG=0
    printf '    prevent_destroy dipasang kembali.\n'
  fi
  ((kode == 0)) || printf '\n%sBerhenti pada kode %d.%s\n' "$_M" "$kode" "$_N" >&2
}
trap bersihkan EXIT

# ---------------------------------------------------------------------------

tahap "Preflight"
butuh_alat aws terraform jq git psql pg_dump
butuh_aws_cli
butuh_klien_pg
worktree_bersih
[[ -f $PATCH ]] || galat "Patch tidak ditemukan: $PATCH"
[[ -f $AKAR/infra/terraform.tfvars ]] ||
  galat "infra/terraform.tfvars belum ada — apply tidak dapat berjalan tanpanya."
baik "Alat lengkap, worktree bersih"

sesi_mfa

# --- Pencadangan ------------------------------------------------------------

if ((DUMP)); then
  buka_tunnel
  mkdir -p "$DIR_DUMP"
  SANDI_OWNER="$(sandi_owner)"

  tahap "Memeriksa apakah data berubah"
  SIDIK_KINI="$(sidik_jari)"
  SIDIK_LAMA=""
  [[ -f $BERKAS_SIDIK ]] && SIDIK_LAMA="$(sed -n 's/^sidik=//p' "$BERKAS_SIDIK")"
  lapor "sidik sekarang : $SIDIK_KINI"
  lapor "sidik tersimpan: ${SIDIK_LAMA:-(belum ada)}"

  if [[ -n $SIDIK_LAMA && $SIDIK_KINI == "$SIDIK_LAMA" && -f $BERKAS_DUMP ]] && ((!PAKSA)); then
    baik "Data tidak berubah sejak $(sed -n 's/^tanggal=//p' "$BERKAS_SIDIK") — dump lama dipakai."
  else
    tahap "Mencadangkan basis data"
    PGPASSWORD="$SANDI_OWNER" pg_dump \
      --format=custom --compress=9 --no-password \
      --host=127.0.0.1 --port="$PORTA_LOKAL" \
      --username=edutrack_owner --dbname=edutrack \
      --file="$BERKAS_DUMP.baru" ||
      galat "pg_dump gagal. Pembongkaran DIHENTIKAN — tidak ada cadangan."

    # Ganti bersih hanya sesudah dump baru selesai utuh. Menulis langsung ke
    # nama akhir membuat dump yang gagal di tengah menimpa dump yang baik.
    mv -f "$BERKAS_DUMP.baru" "$BERKAS_DUMP"
    {
      echo "sidik=$SIDIK_KINI"
      echo "tanggal=$(date +%Y-%m-%dT%H:%M:%S%z)"
      echo "ukuran=$(wc -c <"$BERKAS_DUMP" | tr -d ' ')"
    } >"$BERKAS_SIDIK"
    baik "$BERKAS_DUMP ($(du -h "$BERKAS_DUMP" | cut -f1))"
  fi

  unset SANDI_OWNER
  tutup_tunnel
else
  ingat "Pencadangan dilewati atas permintaan --tanpa-dump."
fi

# --- Konfirmasi -------------------------------------------------------------

konfirmasi "HAPUS EDUTRACK" \
  "Seluruh infrastruktur AWS EduTrack akan dihapus: RDS, NAT instance, VPC,
Lambda, CloudFront, kedua bucket, ECR, dan bucket state Terraform.
Cadangan basis data: ${BERKAS_DUMP}"

# --- Membuka pengaman -------------------------------------------------------

tahap "Membuka pengaman yang berupa atribut"
lapor "deletion_protection, skip_final_snapshot, recovery_window, force_destroy"
tf infra apply -auto-approve -var izinkan_hapus=true ||
  galat "apply pembuka pengaman gagal."
baik "Keempatnya terbuka"

tahap "Membuka prevent_destroy"
git -C "$AKAR" apply --check "$PATCH" ||
  galat "Patch tidak cocok dengan berkas Terraform saat ini.
    Ia sengaja tidak dipaksakan: blok lifecycle mungkin sudah berpindah.
    Perbarui $PATCH lebih dahulu."
git -C "$AKAR" apply "$PATCH"
PATCH_TERPASANG=1
baik "Patch terpasang — akan dicabut sendiri saat skrip keluar"

# --- Pembongkaran -----------------------------------------------------------

tahap "Membongkar infra/"
ingat "CloudFront sekitar 15 menit, pelepasan ENI Lambda sekitar 20 menit."
tf infra destroy -auto-approve -var izinkan_hapus=true ||
  galat "destroy pada infra/ gagal. Patch dicabut otomatis; jalankan ulang."
baik "infra/ kosong"

tahap "Menghapus parameter SSM kunci Elice"
# Ia berada di luar Terraform seluruhnya (CK-D-05), sehingga tidak ikut
# terhapus sendiri.
if aws ssm delete-parameter --name /edutrack/ai/elice-api-key --region "$REGION" 2>/dev/null; then
  baik "/edutrack/ai/elice-api-key"
else
  lapor "Tidak ada — mungkin sudah terhapus sebelumnya."
fi

tahap "Membongkar bootstrap/"
# Bucket state menyimpan state yang sedang dipakai perintah ini juga. Ia
# dikeluarkan dari state lebih dahulu, lalu dihapus paling akhir dengan CLI —
# membiarkan Terraform menghapusnya berarti ia menulis state ke bucket yang
# baru saja dilenyapkannya sendiri.
for sumber in \
  aws_s3_bucket_policy.state_wajib_tls \
  aws_s3_bucket_public_access_block.state \
  aws_s3_bucket_server_side_encryption_configuration.state \
  aws_s3_bucket_versioning.state \
  aws_s3_bucket.state; do
  tf bootstrap state rm "$sumber" >/dev/null 2>&1 || true
done
lapor "Bucket state dikeluarkan dari state Terraform"

tf bootstrap destroy -auto-approve || galat "destroy pada bootstrap/ gagal."
baik "ECR terhapus"

# --- Bucket state, tindakan terakhir ----------------------------------------

BUCKET_STATE="edutrack-tfstate-$(aws sts get-caller-identity --query Account --output text)"

tahap "Menghapus bucket state $BUCKET_STATE"
# `aws s3 rb --force` hanya membuang objek versi terkini. Bucket ini berversi,
# sehingga versi lama dan delete marker tetap tertinggal dan penghapusan bucket
# ditolak dengan BucketNotEmpty yang tidak menyebutkan sebabnya.
TMP="$(umask 077 && mktemp -d)"
while :; do
  # Kedua berkas diisi lebih dahulu: panggilan yang gagal meninggalkan berkas
  # kosong, dan `jq -s` atas berkas kosong menghentikan skrip di sini — tepat
  # ketika seluruh sisanya sudah terhapus.
  echo '{"Objects":[]}' >"$TMP/versi.json"
  echo '{"Objects":[]}' >"$TMP/penanda.json"

  aws s3api list-object-versions --bucket "$BUCKET_STATE" --max-items 500 \
    --query '{Objects: (Versions || `[]`)[].{Key:Key,VersionId:VersionId}}' \
    --output json >"$TMP/versi.json" 2>/dev/null || break
  aws s3api list-object-versions --bucket "$BUCKET_STATE" --max-items 500 \
    --query '{Objects: (DeleteMarkers || `[]`)[].{Key:Key,VersionId:VersionId}}' \
    --output json >"$TMP/penanda.json" 2>/dev/null || true

  jq -s '{Objects: (.[0].Objects + .[1].Objects), Quiet: true}' \
    "$TMP/versi.json" "$TMP/penanda.json" >"$TMP/hapus.json"

  [[ $(jq '.Objects | length' "$TMP/hapus.json") -eq 0 ]] && break
  aws s3api delete-objects --bucket "$BUCKET_STATE" \
    --delete "file://$TMP/hapus.json" >/dev/null
done

if aws s3api delete-bucket --bucket "$BUCKET_STATE" --region "$REGION" 2>/dev/null; then
  baik "$BUCKET_STATE terhapus"
else
  lapor "Sudah tidak ada."
fi

rm -rf "$AKAR/infra/.terraform" "$AKAR/bootstrap/.terraform" \
  "$AKAR/bootstrap/terraform.tfstate" "$AKAR/bootstrap/terraform.tfstate.backup"

# --- Pembuktian -------------------------------------------------------------
#
# Skrip tidak melapor "selesai" berdasarkan keyakinannya sendiri, melainkan
# berdasarkan sapuan yang membuktikan tidak ada sisa yang ditagih.

tahap "Menyapu sisa"
SISA=0

tersisa() {
  local jml="$1" apa="$2"
  # Panggilan yang gagal menghasilkan keluaran kosong, dan kosong yang dibaca
  # sebagai nol akan melaporkan "nihil" atas sesuatu yang belum diperiksa sama
  # sekali. Langkah ini ada justru untuk membuktikan, sehingga ketidaktahuan
  # wajib terbaca berbeda daripada ketiadaan.
  if [[ ! $jml =~ ^[0-9]+$ ]]; then
    ingat "$apa: TIDAK DAPAT DIPERIKSA — periksa dengan tangan"
    SISA=$((SISA + 1))
  elif ((jml > 0)); then
    ingat "$apa: $jml masih berdiri"
    SISA=$((SISA + jml))
  else
    baik "$apa: nihil"
  fi
}

tersisa "$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'length(Reservations[].Instances[])' --output text)" "EC2"

tersisa "$(aws rds describe-db-instances --region "$REGION" \
  --query 'length(DBInstances)' --output text)" "RDS"

tersisa "$(aws ec2 describe-addresses --region "$REGION" \
  --query 'length(Addresses)' --output text)" "Elastic IP"

tersisa "$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter Name=state,Values=available,pending \
  --query 'length(NatGateways)' --output text)" "NAT Gateway"

tersisa "$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)" "Load Balancer"

tersisa "$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters 'Key=Proyek,Values=edutrack' \
  --query 'length(ResourceTagMappingList)' --output text)" "Bertag Proyek=edutrack"

# --- Laporan ----------------------------------------------------------------

tahap "Selesai"
if ((SISA == 0)); then
  baik "Tidak ada sumber daya berbiaya yang tersisa di $REGION."
else
  ingat "Masih ada $SISA sumber daya. Periksa daftar di atas sebelum menutup."
fi

cat <<RINGKAS

  Cadangan basis data : ${BERKAS_DUMP}
  Sengaja dibiarkan   : OIDC provider GitHub, user Andreas, grup Edutrack-dev,
                        role edutrack-terraform — seluruhnya berbiaya nol, dan
                        tanpa ketiganya tidak ada yang dapat meminjam apa pun.

  Bangun kembali      : ./skrip/naikkan.sh

RINGKAS
