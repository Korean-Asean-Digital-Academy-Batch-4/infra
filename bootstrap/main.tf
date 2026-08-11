data "aws_caller_identity" "ini" {}

locals {
  # Nama bucket S3 bersifat unik sedunia, sehingga ID akun disertakan alih-alih
  # dikarang. Tidak ada rahasia di dalamnya: ID akun sudah tercetak pada setiap
  # ARN yang dipakai sehari-hari.
  nama_bucket_state = "edutrack-tfstate-${data.aws_caller_identity.ini.account_id}"
}

# ---------------------------------------------------------------------------
# Penyimpanan state Terraform — DEPLOYMENT.md §2.3
#
# Konfigurasi inilah yang membuat bucket tempat state-nya sendiri kelak
# disimpan, sehingga apply pertama berjalan dengan backend lokal. Lihat
# versions.tf dan README.md.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.nama_bucket_state

  # Kehilangan state berarti Terraform tidak lagi mengenali satu pun sumber
  # daya yang sudah ada — memulihkannya menuntut `terraform import` satu per
  # satu atas seluruh infrastruktur.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  # Versioning bukan kemewahan di sini: ia satu-satunya jalan pulih dari apply
  # yang merusak state, karena versi sebelumnya tetap dapat diambil.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  # State memuat seluruh atribut sumber daya, termasuk yang tidak pernah
  # dimaksudkan terlihat. Keempatnya dinyalakan tanpa kecuali.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state_wajib_tls" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_wajib_tls.json
}

data "aws_iam_policy_document" "state_wajib_tls" {
  statement {
    sid       = "TolakTanpaTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Penguncian state memakai berkas kunci di dalam bucket yang sama — CK-D-04.
# Tidak ada tabel DynamoDB yang dibuat.

# ---------------------------------------------------------------------------
# Repositori image — DEPLOYMENT.md §2.3 dan §2.5
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name = var.nama_ecr

  # Lambda version mengunci digest image. Menghapus repositori ini membuat
  # setiap version yang pernah diterbitkan tidak dapat dijalankan lagi,
  # sehingga rollback kehilangan sasarannya — DEPLOYMENT.md §2.5.
  lifecycle {
    prevent_destroy = true
  }

  # MUTABLE, bukan IMMUTABLE. Tag `:bootstrap` didorong ulang setiap kali
  # lingkungan dibangun kembali dari nol, dan IMMUTABLE membuat langkah 2 pada
  # §2.3 gagal pada percobaan kedua. Tag rilis sendiri berupa git SHA, sehingga
  # tidak pernah dipakai ulang untuk isi yang berbeda.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  # Hanya image TANPA tag yang dibersihkan. Aturan yang menghapus image bertag
  # akan menghapus image yang masih dirujuk sebuah Lambda version, dan
  # akibatnya baru terasa saat rollback — DEPLOYMENT.md §2.5.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Hapus image tanpa tag yang lebih tua dari ${var.umur_image_tanpa_tag_hari} hari"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.umur_image_tanpa_tag_hari
        }
        action = { type = "expire" }
      }
    ]
  })
}
