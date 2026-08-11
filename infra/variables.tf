variable "region" {
  description = "Region AWS. Ditetapkan CK-16 pada Techstack.md."
  type        = string
  default     = "ap-southeast-3"
}

variable "nama_ecr" {
  description = "Nama repositori ECR — DEPLOYMENT.md §2.4. Dibuat `bootstrap/`."
  type        = string
  default     = "edutrack"
}

variable "nama_fungsi_api" {
  description = "Salah satu dari empat nama yang disepakati Terraform dan workflow — DEPLOYMENT.md §2.4."
  type        = string
  default     = "edutrack-api"
}

variable "nama_fungsi_migrate" {
  description = "Salah satu dari empat nama yang disepakati Terraform dan workflow — DEPLOYMENT.md §2.4."
  type        = string
  default     = "edutrack-migrate"
}

variable "nama_alias" {
  description = "Alias rilis. Ke mana ia menunjuk dimiliki CI, bukan Terraform — CK-D-02."
  type        = string
  default     = "live"
}

# ---------------------------------------------------------------------------
# Jaringan — ARCHITECTURE.md Pasal 2 dan 12
# ---------------------------------------------------------------------------

variable "cidr_vpc" {
  description = "Rentang alamat VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "zona" {
  description = <<-EOT
    Dua zona ketersediaan. Dua, bukan satu, karena RDS menuntut subnet group
    yang meliputi sekurang-kurangnya dua zona — bahkan pada instance Single-AZ.
  EOT
  type        = list(string)
  default     = ["ap-southeast-3a", "ap-southeast-3b"]
}

variable "jenis_nat" {
  description = <<-EOT
    NAT instance, bukan NAT Gateway — Techstack.md §8.2. Selisihnya sekitar $30
    per bulan.

    `t4g.micro`, bukan `t4g.nano` — CK-19. Akun berjalan pada Free Plan, dan
    `t4g.nano` **tidak** termasuk daftar tipe yang eligible di `ap-southeast-3`
    sehingga `RunInstances` menolaknya. Tetap arm64: `t4g.micro` ada pada daftar
    itu, jadi AMI-nya tidak perlu berganti arsitektur.

    Daftar eligible region ini per 11 Agustus 2026 — `c7i-flex.large`,
    `t4g.small`, `t4g.micro`, `t3.micro`, `t3.small`, `m7i-flex.large`. Periksa
    ulang sebelum menggantinya:

        aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
          --query 'InstanceTypes[].InstanceType' --output text --region ap-southeast-3
  EOT
  type        = string
  default     = "t4g.micro"

  # AMI-nya dibaca dari parameter SSM arm64 (`jaringan.tf`). Tipe x86 seperti
  # `t3.micro` lolos sebagai teks, lalu gagal saat `RunInstances` dengan keluhan
  # yang tidak menyebut arsitektur sama sekali. Ditolak di sini supaya
  # kegagalannya muncul pada `plan`, bukan di tengah `apply`.
  validation {
    condition     = startswith(var.jenis_nat, "t4g.")
    error_message = "jenis_nat wajib keluarga t4g — AMI NAT dipatok arm64. Untuk memakai tipe x86, ganti pula parameter SSM AMI pada jaringan.tf."
  }
}

# ---------------------------------------------------------------------------
# Basis data — Techstack.md §4.1
# ---------------------------------------------------------------------------

variable "versi_postgres" {
  description = "Mayor saja; minor dinaikkan RDS sendiri lewat auto_minor_version_upgrade."
  type        = string
  default     = "17"
}

variable "kelas_rds" {
  description = "db.t4g.micro Single-AZ — Techstack.md §4.1 dan C-06."
  type        = string
  default     = "db.t4g.micro"
}

variable "penyimpanan_rds_gb" {
  description = "Penyimpanan gp3. Volume data sekolah kecil — RFC-001 §8.1."
  type        = number
  default     = 20
}

variable "retensi_cadangan_hari" {
  description = <<-EOT
    Pencadangan otomatis. **Satu hari, bukan tujuh — CK-19.** Free Plan menolak
    retensi di atas batasnya dengan `FreeTierRestrictionError`, dan galatnya
    tidak menyebut angka maksimumnya.

    **Apabila `apply` masih menolak nilai 1, turunkan ke 0 lewat
    `terraform.tfvars`** — tanpa perubahan kode. Nilai 0 mematikan pencadangan
    otomatis beserta point-in-time recovery seluruhnya.

    Cadangan yang sesungguhnya bersandar pada **snapshot manual** yang
    dijalankan sebelum tindakan berisiko, dan snapshot manual tidak dibatasi
    retensi ini:

        aws rds create-db-snapshot --db-instance-identifier edutrack \
          --db-snapshot-identifier "edutrack-$(date +%Y%m%d-%H%M)" --region ap-southeast-3

    Kebijakan yang sesungguhnya menunggu **V6** pada ATURAN-DAN-KRITERIA §5.
  EOT
  type        = number
  default     = 1
}

variable "nama_basis_data" {
  description = "Nama basis data di dalam instance."
  type        = string
  default     = "edutrack"
}

variable "pengguna_master" {
  description = <<-EOT
    Nama role master. Ia adalah `edutrack_owner` itu sendiri — satu-satunya role
    yang boleh DDL (Techstack.md §7). Kata sandinya dibangkitkan, disimpan, dan
    dirotasi RDS; Terraform hanya membaca ARN-nya — CK-D-06.
  EOT
  type        = string
  default     = "edutrack_owner"
}

# ---------------------------------------------------------------------------
# Fungsi Lambda — ARCHITECTURE.md Pasal 6
# ---------------------------------------------------------------------------

variable "memori_lambda_mb" {
  description = "1024 MB. Memori juga menentukan porsi CPU — ARCHITECTURE.md Pasal 6."
  type        = number
  default     = 1024
}

variable "batas_waktu_api_detik" {
  description = "Request terpanjang adalah finalisasi sekelas, beranggaran lunak 20 detik."
  type        = number
  default     = 30
}

variable "batas_waktu_migrate_detik" {
  description = <<-EOT
    Lebih longgar daripada fungsi `api`, dan itu bukan ketidakkonsistenan: yang
    dibatasi keduanya berbeda. Batas fungsi `api` menjaga pengalaman pengguna;
    batas fungsi `migrate` hanya mencegah migrasi yang menggantung memegang
    kunci selamanya — DEPLOYMENT.md §6.5 dan CK-D-08.
  EOT
  type        = number
  default     = 300
}

variable "concurrency_api" {
  description = <<-EOT
    Rem terakhir. Plafon `db.t4g.micro` sekitar 106 koneksi, sehingga 40
    instance serentak tetap aman. Request ke-41 memperoleh 429 yang dapat
    diulang — ARCHITECTURE.md Pasal 6, CK-18.
  EOT
  type        = number
  default     = 40
}

variable "retensi_log_hari" {
  description = "Retensi CloudWatch Logs kedua fungsi."
  type        = number
  default     = 30
}

variable "umur_arsip_zip_hari" {
  description = <<-EOT
    Arsip ZIP unduhan sekelas tidak pernah dipakai ulang dan dihapus aturan daur
    hidup — ARCHITECTURE.md Pasal 11.
  EOT
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Jalur AI — Techstack.md §6
# ---------------------------------------------------------------------------

variable "elice_base_url" {
  description = <<-EOT
    Berhenti pada id endpoint; `/v1/chat/completions` ditambahkan adapter.
    **Bukan rahasia** — yang rahasia hanya kuncinya, dan kunci itu berada di SSM
    Parameter Store di luar Terraform (CK-D-05). Tidak ada nilai bawaan: id
    endpoint berbeda per akun, dan menebaknya menghasilkan `404
    model_not_found` yang menyesatkan (payload.md §1).
  EOT
  type        = string
}

variable "elice_model" {
  description = "Daftar nilai yang sah: GET {base}/v1/models."
  type        = string
  default     = "gemini-3.6-flash"
}

variable "parameter_kunci_ai" {
  description = "Nama parameter SSM. Isinya di luar Terraform seluruhnya — CK-D-05."
  type        = string
  default     = "/edutrack/ai/elice-api-key"
}

# ---------------------------------------------------------------------------
# OIDC — DEPLOYMENT.md §9.4
# ---------------------------------------------------------------------------

variable "sub_oidc_backend" {
  description = <<-EOT
    Nilai `sub` yang **sungguh-sungguh dikirim GitHub**, bukan format baku.
    Organisasi ini menyalakan custom subject claim di tingkat organisasi,
    sehingga `sub`-nya memuat id numerik organisasi dan repositori —
    Gitaction.md. Trust policy yang memakai format baku tidak pernah cocok, dan
    AWS menolak seluruh permintaan tanpa petunjuk apa pun.
  EOT
  type        = string
  default     = "repo:Korean-Asean-Digital-Academy-Batch-4@307598735/backend@1325655840:ref:refs/heads/main"
}

variable "sub_oidc_frontend" {
  description = <<-EOT
    Setara di atas bagi repositori frontend. **Belum diketahui**: id numerik
    repositori baru terbaca dari log diagnostik workflow repositori itu sendiri
    (Gitaction.md), dan repositorinya belum ada. Selama kosong, role
    `edutrack-gha-frontend` tidak dibuat — lebih baik tidak ada daripada ada
    dengan trust policy yang salah.
  EOT
  type        = string
  default     = ""
}
