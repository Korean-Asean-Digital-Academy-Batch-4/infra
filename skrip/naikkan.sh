#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Membangun kembali seluruh lingkungan EduTrack di AWS — DEPLOYMENT.md CK-D-09.
#
#   ./skrip/naikkan.sh                dari nol, pulihkan dump bila ada
#   ./skrip/naikkan.sh --tanpa-dump   biarkan basis data kosong
#   ./skrip/naikkan.sh --tanpa-rilis  berhenti sesudah rahasia terisi
#
# Tepat DUA kali menuntut manusia, dan keduanya memang tidak dapat diwakilkan:
# kode MFA dari ponsel, dan kunci API Elice. Sisanya berjalan sendiri karena
# seluruh rahasia lain dibangkitkan — RDS membangkitkan kata sandi masternya,
# skrip ini membangkitkan kata sandi app_rw dan app_ro.
# ---------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=lib-sesi.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sesi.sh"

PULIHKAN=1
RILIS=1
for arg in "$@"; do
  case "$arg" in
  --tanpa-dump) PULIHKAN=0 ;;
  --tanpa-rilis) RILIS=0 ;;
  *) galat "Argumen tidak dikenal: $arg" ;;
  esac
done

PATCH_BACKEND="$AKAR/skrip/backend-lokal.patch"
PATCH_TERPASANG=0
TMP=""

bersihkan() {
  local kode=$?
  tutup_tunnel
  [[ -n $TMP ]] && rm -rf "$TMP"
  if ((PATCH_TERPASANG)); then
    git -C "$AKAR" checkout -- bootstrap/versions.tf 2>/dev/null || true
    PATCH_TERPASANG=0
  fi
  ((kode == 0)) || printf '\n%sBerhenti pada kode %d.%s\n' "$_M" "$kode" "$_N" >&2
}
trap bersihkan EXIT

# ---------------------------------------------------------------------------

tahap "Preflight"
butuh_alat aws terraform docker jq git psql pg_restore
butuh_aws_cli
butuh_klien_pg
worktree_bersih
docker info >/dev/null 2>&1 || galat "Docker daemon tidak berjalan."
[[ -n $DIR_BACKEND && -f $DIR_BACKEND/Dockerfile ]] ||
  galat "Repositori backend tidak ditemukan di $DIR_BACKEND — setel DIR_BACKEND."
command -v gh >/dev/null 2>&1 || ingat "gh tidak ada — ALAMAT_PUBLIK harus disetel tangan."
baik "Alat lengkap, worktree bersih"

sesi_mfa
ID_AKUN="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_STATE="edutrack-tfstate-$ID_AKUN"

# --- bootstrap/ -------------------------------------------------------------
#
# Bucket state dibuat oleh konfigurasi yang state-nya sendiri kelak tinggal di
# dalamnya. Apply pertama karenanya berjalan dengan backend lokal, lalu state-nya
# dipindahkan — persis prosedur pada bootstrap/versions.tf.

tahap "Membangun bootstrap/ — bucket state dan ECR"

if aws s3api head-bucket --bucket "$BUCKET_STATE" 2>/dev/null; then
  lapor "Bucket state sudah ada; backend S3 dipakai langsung."
  tf bootstrap init -input=false -reconfigure >/dev/null
else
  git -C "$AKAR" apply "$PATCH_BACKEND" ||
    galat "Patch backend lokal tidak cocok dengan bootstrap/versions.tf."
  PATCH_TERPASANG=1
  lapor "Backend sementara dilokalkan"

  tf bootstrap init -input=false >/dev/null

  # Nama bucket S3 bersifat global. Membuatnya kembali sesaat setelah dihapus
  # kadang ditolak sampai propagasinya selesai, dan satu-satunya jalan keluar
  # adalah menunggu.
  n=0
  until tf bootstrap apply -auto-approve; do
    ((n++))
    ((n < 6)) || galat "apply pada bootstrap/ gagal $n kali.
    Bila sebabnya nama bucket '$BUCKET_STATE' masih dipesan AWS, tidak ada yang
    dapat dilakukan selain menunggu — coba lagi beberapa menit kemudian."
    ingat "Gagal; menunggu 60 detik lalu mencoba lagi ($n/5)."
    sleep 60
  done

  git -C "$AKAR" checkout -- bootstrap/versions.tf
  PATCH_TERPASANG=0
  lapor "Backend S3 dinyalakan kembali"

  tf bootstrap init -input=false -migrate-state -force-copy >/dev/null ||
    galat "Pemindahan state ke S3 gagal."
  rm -f "$AKAR/bootstrap/terraform.tfstate" "$AKAR/bootstrap/terraform.tfstate.backup"
fi

URL_ECR="$(terraform -chdir="$AKAR/bootstrap" output -raw url_ecr)"
baik "ECR: $URL_ECR"

# --- Image :bootstrap -------------------------------------------------------
#
# Fungsi Lambda tidak dapat dibuat tanpa image — §2.3. Tag `:bootstrap` sengaja
# dipilih agar tampak sementara.

tahap "Mendorong image :bootstrap"
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "${URL_ECR%%/*}" >/dev/null
docker build --platform linux/arm64 -t "$URL_ECR:bootstrap" "$AKAR/bootstrap-image" >/dev/null
docker push "$URL_ECR:bootstrap" >/dev/null
baik "$URL_ECR:bootstrap"

# --- infra/ -----------------------------------------------------------------

tahap "Membangun infra/"
if [[ ! -f $AKAR/infra/terraform.tfvars ]]; then
  lapor "terraform.tfvars belum ada."
  printf '    Alamat endpoint Elice (berhenti pada id, tanpa /v1/...): '
  read -r base_url
  [[ $base_url == https://* ]] || galat "Alamat harus diawali https://"
  printf 'elice_base_url = "%s"\n' "$base_url" >"$AKAR/infra/terraform.tfvars"
  baik "terraform.tfvars ditulis"
fi

tf infra init -input=false >/dev/null
ingat "RDS sekitar 10 menit, CloudFront sekitar 15 menit."
tf infra apply -auto-approve || galat "apply pada infra/ gagal."
baik "Infrastruktur berdiri"

DOMAIN="$(keluaran domain_cloudfront)"
NAMA_API="$(keluaran nama_fungsi_api)"
NAMA_MIGRATE="$(keluaran nama_fungsi_migrate)"
NAMA_ALIAS="$(keluaran nama_alias)"
ROLE_OIDC="$(keluaran role_oidc_backend)"

# --- Kunci Elice ------------------------------------------------------------
#
# Parameter SSM berada di luar Terraform seluruhnya (CK-D-05): resource
# aws_ssm_parameter mewajibkan atribut `value`, sehingga tidak ada cara
# membuatnya tanpa kuncinya masuk ke state.

tahap "Kunci API Elice"
if aws ssm get-parameter --name /edutrack/ai/elice-api-key --region "$REGION" \
  --query 'Parameter.Version' --output text >/dev/null 2>&1; then
  baik "Sudah ada — dilewati."
else
  TMP="$(umask 077 && mktemp -d)"
  printf '    Tempelkan kunci API Elice (tidak ditampilkan): '
  read -rs kunci
  printf '\n'
  [[ -n $kunci ]] || galat "Kunci kosong."

  # Nilainya tidak pernah muncul pada baris perintah — §5.1 aturan 1. Argumen
  # perintah terbaca seluruh pengguna mesin lewat `ps`.
  jq -n --arg v "$kunci" '{
    Name: "/edutrack/ai/elice-api-key",
    Type: "SecureString",
    Value: $v,
    Description: "Kunci API Elice AI Cloud - Techstack sec 6",
    Tier: "Standard"
  }' >"$TMP/kunci.json"
  unset kunci

  aws ssm put-parameter --cli-input-json "file://$TMP/kunci.json" --region "$REGION" >/dev/null
  rm -rf "$TMP"
  TMP=""
  baik "/edutrack/ai/elice-api-key tersimpan"
fi

# --- Basis data -------------------------------------------------------------

buka_tunnel
TMP="$(umask 077 && mktemp -d)"
SANDI_OWNER="$(sandi_owner)"

# Role dibuat migrasi 0009, tetapi pemulihan dump menuntutnya sudah ada lebih
# dahulu: dump memuat GRANT yang menunjuk keduanya, dan GRANT kepada role yang
# belum ada membuat seluruh pemulihan gagal. Penjaganya sama persis dengan yang
# dipakai migrasi, sehingga menjalankan keduanya tidak pernah bertabrakan.
tahap "Memastikan role app_rw dan app_ro ada"
psql_owner -q <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro') THEN
        CREATE ROLE app_ro LOGIN;
    END IF;
END
$$;
SQL
baik "Keduanya ada"

if ((PULIHKAN)) && [[ -f $BERKAS_DUMP ]]; then
  tahap "Memulihkan basis data dari $BERKAS_DUMP"
  lapor "dump $(sed -n 's/^tanggal=//p' "$BERKAS_SIDIK" 2>/dev/null || echo '-')"
  PGPASSWORD="$SANDI_OWNER" pg_restore \
    --no-password --exit-on-error \
    --host=127.0.0.1 --port="$PORTA_LOKAL" \
    --username=edutrack_owner --dbname=edutrack \
    "$BERKAS_DUMP" || galat "pg_restore gagal."
  baik "Data pulih"
elif ((PULIHKAN)); then
  lapor "Tidak ada dump di $BERKAS_DUMP — basis data dibiarkan kosong."
fi

# --- Kata sandi kedua role --------------------------------------------------
#
# Dibangkitkan SEKALI ke dalam variabel, lalu ditulis ke DUA tempat dari
# variabel yang sama — §5.1. Membangkitkannya dua kali menghasilkan dua nilai
# berbeda, dan kegagalannya baru muncul pada rilis pertama sebagai
# `password authentication failed`.

tahap "Mengisi kredensial app_rw dan app_ro"
for peran in app_rw app_ro; do
  sandi="$(openssl rand -base64 24 | tr -d '\n=/+')"

  printf "ALTER ROLE %s LOGIN PASSWORD '%s';\n" "$peran" "$sandi" >"$TMP/$peran.sql"
  psql_owner -q -f "$TMP/$peran.sql"

  jq -n --arg u "$peran" --arg p "$sandi" '{username: $u, password: $p}' >"$TMP/$peran.json"
  # put-secret-value, bukan create-secret: wadahnya sudah dibuat Terraform.
  aws secretsmanager put-secret-value \
    --secret-id "edutrack/db/$peran" \
    --secret-string "file://$TMP/$peran.json" \
    --region "$REGION" >/dev/null
  unset sandi

  # Memeriksa keberadaan versi rahasia TIDAK membuktikan apa pun — §5.1. Yang
  # membuktikannya hanya membaca kembali dari Secrets Manager, lalu masuk.
  aws secretsmanager get-secret-value --secret-id "edutrack/db/$peran" \
    --region "$REGION" --query SecretString --output text | jq -r .password >"$TMP/uji"
  PGPASSWORD="$(cat "$TMP/uji")" psql \
    "host=127.0.0.1 port=$PORTA_LOKAL dbname=edutrack user=$peran sslmode=require" \
    -qtAX -c 'SELECT 1' >/dev/null ||
    galat "$peran tidak dapat masuk memakai kata sandi yang dibaca balik dari Secrets Manager."
  baik "$peran — tersimpan dan terbukti dapat masuk"
done

unset SANDI_OWNER
rm -rf "$TMP"
TMP=""
tutup_tunnel

if ((!RILIS)); then
  tahap "Berhenti atas permintaan --tanpa-rilis"
  lapor "Infrastruktur dan rahasia siap. Rilis dapat dijalankan CI."
  exit 0
fi

# --- Rilis ------------------------------------------------------------------
#
# Urutan §3.3, termasuk kedua `wait` yang paling mudah terlupa: langkah 4 dan 7
# asinkron, dan menerbitkan version terlalu cepat membekukan image LAMA.

SHA="$(git -C "$DIR_BACKEND" rev-parse HEAD)"
tahap "Membangun dan mendorong image aplikasi"
lapor "tag = $SHA"
docker build --platform linux/arm64 -t "$URL_ECR:$SHA" "$DIR_BACKEND" >/dev/null
docker push "$URL_ECR:$SHA" >/dev/null
baik "$URL_ECR:$SHA"

tahap "Menerapkan migrasi"
aws lambda update-function-code --function-name "$NAMA_MIGRATE" \
  --image-uri "$URL_ECR:$SHA" --region "$REGION" >/dev/null
aws lambda wait function-updated --function-name "$NAMA_MIGRATE" --region "$REGION"

TMP="$(umask 077 && mktemp -d)"
aws lambda invoke --function-name "$NAMA_MIGRATE" --region "$REGION" \
  --cli-binary-format raw-in-base64-out --payload '{}' \
  --cli-read-timeout 300 "$TMP/jawaban.json" >"$TMP/ringkasan.json"

# DUA pemeriksaan, dan keduanya diperlukan — deploy.yml langkah 6.
# `FunctionError` hanya muncul ketika fungsinya sendiri melempar. Migrasi yang
# gagal dilaporkan sebagai jawaban HTTP 500 DI DALAM payload, dan invocation-nya
# tetap berhasil; tanpa pemeriksaan kedua, rilis berlanjut di atas skema lama.
if jq -e '.FunctionError' "$TMP/ringkasan.json" >/dev/null; then
  cat "$TMP/jawaban.json" >&2
  galat "Fungsi migrate melempar galat."
fi

# Dua bentuk jawaban diterima: adapter membungkusnya sebagai {statusCode, body}
# pada sebagian jalur dan meneruskannya apa adanya pada jalur lain. Yang
# diperiksa isinya, bukan bungkusnya.
if ! jq -e '(if type == "object" and has("body")
             then (.body | fromjson? // {}) else . end)
            | .data.berhasil == true' "$TMP/jawaban.json" >/dev/null; then
  cat "$TMP/jawaban.json" >&2
  galat "Migrasi tidak melaporkan berhasil. Aplikasi TIDAK disentuh — §3.3 langkah 6."
fi
baik "$(jq -r '(if type == "object" and has("body")
                then (.body | fromjson? // {}) else . end)
               | .data.diterapkan | if length == 0 then "tidak ada migrasi baru"
                                    else "\(length) migrasi diterapkan" end' \
  "$TMP/jawaban.json")"

tahap "Merilis aplikasi"
aws lambda update-function-code --function-name "$NAMA_API" \
  --image-uri "$URL_ECR:$SHA" --region "$REGION" >/dev/null
aws lambda wait function-updated --function-name "$NAMA_API" --region "$REGION"

VERSI="$(aws lambda publish-version --function-name "$NAMA_API" \
  --region "$REGION" --query Version --output text)"
aws lambda update-alias --function-name "$NAMA_API" \
  --name "$NAMA_ALIAS" --function-version "$VERSI" --region "$REGION" >/dev/null
baik "alias $NAMA_ALIAS → version $VERSI"

# --- Setelan repositori backend ---------------------------------------------
#
# Domain CloudFront BERBEDA setiap kali lingkungan dibangun kembali. Terlewat,
# langkah 11 §3.3 tetap lulus sambil menguji alamat yang sudah mati.

if command -v gh >/dev/null 2>&1; then
  tahap "Memperbarui setelan repositori backend"
  if gh variable set ALAMAT_PUBLIK --body "$DOMAIN" \
    --repo Korean-Asean-Digital-Academy-Batch-4/backend 2>/dev/null; then
    baik "ALAMAT_PUBLIK = $DOMAIN"
    gh secret set AWS_ROLE_ARN --body "$ROLE_OIDC" \
      --repo Korean-Asean-Digital-Academy-Batch-4/backend 2>/dev/null &&
      baik "AWS_ROLE_ARN = $ROLE_OIDC"
  else
    ingat "gh gagal — setel ALAMAT_PUBLIK=$DOMAIN dengan tangan."
  fi
else
  ingat "Setel ALAMAT_PUBLIK=$DOMAIN pada repositori backend dengan tangan."
fi

# --- Pembuktian -------------------------------------------------------------
#
# Alamatnya /api/healthz, bukan /healthz: CloudFront hanya meneruskan /api/* ke
# Lambda, dan /healthz di akar dilayani bucket frontend — pemeriksaan yang
# selalu lulus dan karenanya tidak memeriksa apa pun.

tahap "Menguji jalur nyata lewat CloudFront"
n=0
until kode="$(curl -s -o "$TMP/sehat.json" -w '%{http_code}' "$DOMAIN/api/healthz")" &&
  [[ $kode == 200 ]]; do
  ((n++))
  ((n < 20)) || {
    cat "$TMP/sehat.json" >&2
    galat "GET $DOMAIN/api/healthz menjawab ${kode:-gagal} sesudah $n percobaan."
  }
  sleep 15
done
baik "GET $DOMAIN/api/healthz → 200"
rm -rf "$TMP"
TMP=""

tahap "Selesai"
cat <<RINGKAS

  Alamat publik  : $DOMAIN
  Commit berjalan: $SHA
  Version alias  : $NAMA_ALIAS → $VERSI

  Bongkar kembali: ./skrip/turunkan.sh

RINGKAS
