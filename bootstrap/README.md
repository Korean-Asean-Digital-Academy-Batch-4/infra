# `bootstrap/` — dijalankan sekali seumur proyek

Membuat tiga hal yang tidak dapat dibuat oleh `infra/` karena `infra/`
membutuhkannya untuk berjalan: **bucket state**, **penguncian state**, dan
**repositori ECR**. Alasan pemisahannya pada
[DEPLOYMENT.md §2.3](../../context/DEPLOYMENT.md) — fungsi Lambda tidak dapat
dibuat tanpa image, dan image tidak dapat didorong sebelum ECR ada.

## Prasyarat

Role `edutrack-terraform` sudah ada dan dapat dipinjam, sesuai
[DEPLOYMENT.md §9.6](../../context/DEPLOYMENT.md):

```bash
AWS_PROFILE=edutrack aws sts get-caller-identity
```

Keluarannya wajib memuat `assumed-role/edutrack-terraform/…`, **bukan**
`user/<nama>`. Selama belum, gerbang §9.8 belum lulus dan pengguna root belum
boleh ditinggalkan.

## Urutan

### 1. Apply pertama — backend masih lokal

```bash
AWS_PROFILE=edutrack terraform init
```

```bash
AWS_PROFILE=edutrack terraform apply
```

State-nya tersimpan sebagai `terraform.tfstate` di direktori ini. Itu memang
disengaja: konfigurasi ini yang membuat bucket tempat state akan disimpan,
sehingga ia tidak dapat menyimpan state di tempat yang belum ada.

### 2. Pindahkan state ke bucket yang baru dibuat

Salin nilai `nama_bucket_state` dari keluaran `terraform output`, nyalakan blok
`backend "s3"` pada [versions.tf](versions.tf), isikan nama bucketnya, lalu:

```bash
AWS_PROFILE=edutrack terraform init -migrate-state
```

Sesudah itu `terraform.tfstate` lokal tidak lagi dipakai dan boleh dihapus —
`.gitignore` sudah menahannya agar tidak pernah masuk repositori.

### 3. Dorong image `:bootstrap`

Ini langkah 2 pada [DEPLOYMENT.md §2.3](../../context/DEPLOYMENT.md), dan
dijalankan dari repositori `backend`:

```bash
AWS_PROFILE=edutrack ../scripts/dorong-image-bootstrap.sh
```

Tag `:bootstrap` sengaja dipilih agar tampak sementara. Tag seperti `:v1`
mengundang orang mengira angkanya berarti sesuatu dan perlu dinaikkan.

### 4. Lanjut ke `infra/`

Sesudah ECR memuat satu image, fungsi Lambda dapat dibuat.

## Yang sengaja tidak ada di sini

**Tabel DynamoDB penguncian.** Penguncian state memakai berkas kunci di dalam
bucket yang sama, lewat `use_lockfile = true` — **CK-D-04** pada
[DEPLOYMENT.md](../../context/DEPLOYMENT.md). Argumen backend `dynamodb_table`
sudah usang sejak Terraform 1.11.
