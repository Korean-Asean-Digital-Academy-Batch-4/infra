# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Fungsi bersama `turunkan.sh` dan `naikkan.sh` — DEPLOYMENT.md CK-D-09.
#
# Berkas ini DI-SOURCE, bukan dijalankan. Ia tidak melakukan apa pun sendiri;
# seluruh tindakan berasal dari kedua skrip pemanggilnya.
# ---------------------------------------------------------------------------

REGION="${REGION:-ap-southeast-3}"
PROFIL="${PROFIL:-edutrack}"
PORTA_LOKAL="${PORTA_LOKAL:-15432}"

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_BACKEND="${DIR_BACKEND:-$(cd "$AKAR/../backend" 2>/dev/null && pwd || true)}"

DIR_DUMP="${DIR_DUMP:-$HOME/.edutrack/dump}"
BERKAS_DUMP="$DIR_DUMP/edutrack.dump"
BERKAS_SIDIK="$DIR_DUMP/edutrack.sidik"

# --- Keluaran ---------------------------------------------------------------

if [[ -t 1 ]]; then
  _M=$'\033[31m' _H=$'\033[32m' _K=$'\033[33m' _B=$'\033[34m' _T=$'\033[1m' _N=$'\033[0m'
else
  _M='' _H='' _K='' _B='' _T='' _N=''
fi

tahap() { printf '\n%s==> %s%s\n' "$_B$_T" "$*" "$_N"; }
lapor() { printf '    %s\n' "$*"; }
baik() { printf '    %s✓%s %s\n' "$_H" "$_N" "$*"; }
ingat() { printf '    %s!%s %s\n' "$_K" "$_N" "$*" >&2; }
galat() {
  printf '\n%s✗ %s%s\n' "$_M$_T" "$*" "$_N" >&2
  exit 1
}

# --- Preflight --------------------------------------------------------------

butuh_alat() {
  local kurang=()
  for alat in "$@"; do
    command -v "$alat" >/dev/null 2>&1 || kurang+=("$alat")
  done
  ((${#kurang[@]} == 0)) || galat "Alat berikut belum terpasang: ${kurang[*]}"
}

# `aws configure export-credentials` baru ada sejak AWS CLI 2.9 — §9.6.
butuh_aws_cli() {
  local v
  v="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9]*\)\.\([0-9]*\).*|\1 \2|p')"
  # shellcheck disable=SC2086
  set -- $v
  [[ ${1:-0} -gt 2 || (${1:-0} -eq 2 && ${2:-0} -ge 9) ]] ||
    galat "AWS CLI 2.9 atau lebih baru diperlukan; yang terpasang $(aws --version 2>&1)"
}

# `pg_dump` yang lebih TUA daripada servernya menolak bekerja. Yang lebih baru
# tidak apa-apa, dan itulah keadaan yang lazim di mesin pengembang.
butuh_klien_pg() {
  local mayor
  mayor="$(pg_dump --version | sed -n 's|.* \([0-9]*\)\..*|\1|p')"
  [[ ${mayor:-0} -ge 17 ]] ||
    galat "pg_dump 17 atau lebih baru diperlukan (server PostgreSQL 17); terpasang $mayor"
}

worktree_bersih() {
  git -C "$AKAR" diff --quiet && git -C "$AKAR" diff --cached --quiet ||
    galat "Worktree $AKAR tidak bersih.
    Patch prevent_destroy hanya dapat dicabut kembali dengan aman apabila tidak
    ada perubahan lain yang belum di-commit. Commit atau stash dahulu."
}

# --- Sesi AWS ---------------------------------------------------------------

# Peminjaman role menuntut kode MFA dari ponsel, dan Terraform tidak dapat
# menanyakannya sendiri — §9.6. Sesi yang sudah dipinjam CLI diserahkan lewat
# variabel lingkungan. AWS_PROFILE sengaja TIDAK disetel: menyetel keduanya
# sekaligus membuat sumber kredensial menjadi ambigu bagi pembaca berikutnya.
sesi_mfa() {
  tahap "Meminjam role edutrack-terraform"
  lapor "Kode MFA diminta di bawah, kecuali sesi sebelumnya masih hidup."

  local ekspor
  ekspor="$(aws configure export-credentials --profile "$PROFIL" --format env)" ||
    galat "Peminjaman role gagal. Periksa profil '$PROFIL' pada ~/.aws/config — §9.6."
  eval "$ekspor"
  unset AWS_PROFILE
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

  local siapa
  siapa="$(aws sts get-caller-identity --query Arn --output text)" ||
    galat "Kredensial tidak dapat dipakai."
  [[ $siapa == *"assumed-role/edutrack-terraform/"* ]] ||
    galat "Identitas yang diperoleh bukan edutrack-terraform melainkan:
    $siapa
    Gerbang §9.8 belum lulus."
  baik "${siapa##*/}"
}

# --- Terraform --------------------------------------------------------------

tf() { terraform -chdir="$AKAR/$1" "${@:2}"; }

keluaran() {
  terraform -chdir="$AKAR/infra" output -raw "$1" 2>/dev/null ||
    galat "Output Terraform '$1' tidak terbaca. Apakah infra/ sudah di-apply?"
}

# --- Jalan masuk sementara --------------------------------------------------
#
# `edutrack-rds` hanya menerima dari security group Lambda (jaringan.tf). NAT
# instance memakai security group tersendiri, sehingga port forwarding lewat
# dirinya TIDAK tersambung: paketnya dibuang diam-diam, dan psql menunggu
# jawaban yang tidak akan pernah datang alih-alih gagal.
#
# Aturannya karenanya dibuka sebentar lalu dicabut kembali — persis yang
# dikerjakan dengan tangan pada 12 Agustus 2026 (KEMAJUAN.md). Ia sengaja TIDAK
# dijadikan sumber daya Terraform: jalan masuk yang berdiri tetap melemahkan
# postur yang justru menjadi maksud subnet privat-data.

ID_ATURAN_SEMENTARA=""

sg_id() {
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}

izinkan_nat_ke_rds() {
  local sg_rds sg_nat
  sg_rds="$(sg_id edutrack-rds)"
  sg_nat="$(sg_id edutrack-nat)"
  [[ $sg_rds == sg-* && $sg_nat == sg-* ]] ||
    galat "Security group edutrack-rds atau edutrack-nat tidak ditemukan."

  tahap "Membuka jalan masuk sementara NAT → RDS"
  ID_ATURAN_SEMENTARA="$(aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$sg_rds" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$sg_nat,Description='sementara - skrip/lib-sesi.sh'}]" \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text 2>/dev/null)" || true

  if [[ $ID_ATURAN_SEMENTARA == sgr-* ]]; then
    SG_RDS_DIPAKAI="$sg_rds"
    baik "$ID_ATURAN_SEMENTARA — akan dicabut sendiri saat skrip keluar"
  else
    # Sudah ada aturannya. Ia bukan buatan skrip ini, sehingga TIDAK boleh ikut
    # dicabut — mencabut milik orang lain adalah perubahan yang tidak diminta.
    ID_ATURAN_SEMENTARA=""
    ingat "Jalan masuk sudah ada sebelumnya — dibiarkan apa adanya."
  fi
}

cabut_izin_nat_ke_rds() {
  [[ -n $ID_ATURAN_SEMENTARA ]] || return 0
  aws ec2 revoke-security-group-ingress --region "$REGION" \
    --group-id "$SG_RDS_DIPAKAI" \
    --security-group-rule-ids "$ID_ATURAN_SEMENTARA" >/dev/null 2>&1 &&
    printf '    Jalan masuk sementara dicabut.\n' ||
    ingat "GAGAL mencabut $ID_ATURAN_SEMENTARA pada $SG_RDS_DIPAKAI — cabut dengan tangan."
  ID_ATURAN_SEMENTARA=""
}

# --- Tunnel SSM -------------------------------------------------------------
#
# RDS berada di subnet privat-data yang tidak memiliki rute keluar sama sekali.
# Satu-satunya jalan menuju ke sana adalah port forwarding lewat NAT instance,
# tanpa SSH.

PID_TUNNEL=""
SG_RDS_DIPAKAI=""

buka_tunnel() {
  local id_nat inang
  id_nat="$(keluaran id_instance_nat)"
  inang="$(keluaran inang_rds)"

  tahap "Membuka tunnel ke RDS lewat $id_nat"

  aws ssm start-session \
    --target "$id_nat" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$inang\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$PORTA_LOKAL\"]}" \
    >/dev/null 2>&1 &
  PID_TUNNEL=$!

  local n=0
  until (exec 3<>"/dev/tcp/127.0.0.1/$PORTA_LOKAL") 2>/dev/null; do
    ((n++))
    ((n < 40)) || galat "Tunnel tidak menyala dalam 40 detik.
    Periksa bahwa SSM Agent pada $id_nat sedang berjalan."
    kill -0 "$PID_TUNNEL" 2>/dev/null || galat "Sesi SSM berhenti sendiri.
    Jalankan perintahnya dengan tangan untuk melihat pesan aslinya — infra/README.md."
    sleep 1
  done
  exec 3<&- 2>/dev/null || true
  baik "127.0.0.1:$PORTA_LOKAL → $inang:5432"
}

tutup_tunnel() {
  [[ -n $PID_TUNNEL ]] || return 0
  kill "$PID_TUNNEL" 2>/dev/null || true
  wait "$PID_TUNNEL" 2>/dev/null || true
  PID_TUNNEL=""
}

# --- Kredensial pemilik -----------------------------------------------------
#
# `.pgpass` TIDAK dapat dipakai: kata sandi yang dibangkitkan RDS dapat memuat
# titik dua, dan titik dua adalah pemisah bidang pada berkas itu — barisnya
# terurai salah tanpa satu pun peringatan (§5.1). PGPASSWORD tidak memiliki
# format sama sekali, dan nilainya hanya menjadi lingkungan proses psql.

sandi_owner() {
  local arn
  arn="$(keluaran arn_rahasia_owner)"
  aws secretsmanager get-secret-value \
    --secret-id "$arn" --query SecretString --output text |
    jq -r .password
}

# Argumen psql diteruskan apa adanya. Kata sandi tidak pernah masuk ke `argv`.
#
# `connect_timeout` WAJIB ada. Tanpanya, jalur yang diblokir security group
# tidak menghasilkan penolakan melainkan kesunyian: paketnya dibuang, dan psql
# menunggu selamanya. Kegagalan yang tidak pernah tiba jauh lebih mahal
# daripada kegagalan yang tiba dalam 15 detik.
KONEKSI_OWNER="host=127.0.0.1 port=$PORTA_LOKAL dbname=edutrack user=edutrack_owner sslmode=require connect_timeout=15"

psql_owner() {
  PGPASSWORD="$SANDI_OWNER" psql "$KONEKSI_OWNER" -v ON_ERROR_STOP=1 "$@"
}

# --- Sidik jari data --------------------------------------------------------
#
# Dua dump dari data yang sama TIDAK menghasilkan berkas yang sama: format -Fc
# terkompresi dan memuat stempel waktu. Membandingkan berkas dump karenanya
# selalu berkata "berubah", dan jawabannya baru diperoleh sesudah datanya
# terlanjur ditransfer.
#
# Yang dibandingkan adalah basis datanya. Keluarannya satu baris — sekitar 200
# byte — dan pengurutan menurut hash baris membuatnya tidak bergantung pada
# urutan fisik. Isi yang berubah di tempat terbaca; count(*) saja tidak akan.

sidik_jari() {
  psql_owner -qtAX <<'SQL' | tr -d '[:space:]'
SELECT coalesce(md5(string_agg(tabel || '=' || sidik, ',' ORDER BY tabel)), 'kosong')
FROM (
  SELECT table_name AS tabel,
         (xpath('/row/c/text()', query_to_xml(
           format('SELECT md5(coalesce(string_agg(md5(t.*::text), '''' ORDER BY md5(t.*::text)), '''')) AS c FROM %I.%I t',
                  table_schema, table_name),
           false, true, '')))[1]::text AS sidik
  FROM information_schema.tables
  WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
) s;
SQL
}

# --- Konfirmasi -------------------------------------------------------------

konfirmasi() {
  local diminta="$1" jawab
  printf '\n%s%s%s\n' "$_K$_T" "$2" "$_N"
  printf 'Ketik %s%s%s untuk melanjutkan: ' "$_T" "$diminta" "$_N"
  read -r jawab
  [[ $jawab == "$diminta" ]] || galat "Dibatalkan."
}
