# ---------------------------------------------------------------------------
# Role eksekusi — DEPLOYMENT.md §9.5
#
# Kedua fungsi memakai image yang sama tetapi role yang berbeda, dan pemisahan
# itu menentukan. Fungsi `migrate` menjalankan DDL sehingga membutuhkan
# kredensial `edutrack_owner`; fungsi `api` melayani request dan TIDAK BOLEH
# dapat membacanya. Tanpa pemisahan ini, satu kekeliruan kode pada jalur
# permintaan dapat mengambil kredensial pemilik dan melewati seluruh pemisahan
# app_rw dan app_ro yang dibangun CK-08.
#
# IAM di sini memperkuat jaminan basis data, bukan mengulanginya.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "boleh_dipinjam_lambda" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Kunci KMS terkelola AWS tidak disebut lewat ARN-nya, melainkan lewat layanan
# yang memakainya. ARN kunci terkelola berbeda per akun dan dapat digantikan
# AWS; syarat `kms:ViaService` menyatakan maksud yang sesungguhnya — dekripsi
# hanya boleh terjadi sebagai bagian dari pembacaan rahasia, bukan sebagai
# tindakan tersendiri.
locals {
  via_secretsmanager = "secretsmanager.${var.region}.amazonaws.com"
  via_ssm            = "ssm.${var.region}.amazonaws.com"
}

# --- Fungsi api -------------------------------------------------------------

resource "aws_iam_role" "lambda_api" {
  name               = "edutrack-lambda-api"
  assume_role_policy = data.aws_iam_policy_document.boleh_dipinjam_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_api_vpc" {
  role       = aws_iam_role.lambda_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_api" {
  # Dua rahasia, disebut satu per satu. Rahasia `edutrack_owner` sengaja TIDAK
  # ada di sini, dan ketiadaannya itulah isi pasal ini.
  statement {
    sid     = "BacaKredensialAplikasi"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app_rw.arn,
      aws_secretsmanager_secret.app_ro.arn,
    ]
  }

  statement {
    sid       = "BacaKunciAi"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.ini.account_id}:parameter${var.parameter_kunci_ai}"]
  }

  statement {
    sid       = "DekripsiRahasia"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.via_secretsmanager, local.via_ssm]
    }
  }

  # `s3:DeleteObject` bukan kelebihan izin. Ia diperlukan CK-A-05: setiap
  # koreksi Administrator atas data final menghapus berkas rapor terkait dari S3
  # di dalam transaksi yang sama.
  statement {
    sid       = "BerkasRapor"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.rapor.arn}/*"]
  }

  # ⚠️ Aplikasi TIDAK PERNAH mendaftar isi bucket, dan izin ini tetap wajib.
  #
  # Yang menuntutnya adalah perilaku S3 pada objek yang BELUM ADA: tanpa
  # `s3:ListBucket`, `HeadObject` menjawab 403 alih-alih 404, karena S3 menolak
  # membocorkan keberadaan objek kepada pemanggil yang tidak boleh mendaftarnya.
  #
  # Jalur render-saat-unduh memeriksa keberadaan berkas lebih dahulu, dan 403
  # itu bukan "belum ada" melainkan galat sungguhan — sehingga setiap perenderan
  # gagal sebelum satu pun berkas dibuat. Ditemukan saat B7, dengan gejala
  # `berkas_terender: 0` tanpa satu pun pesan yang menyebut S3.
  #
  # Sasarannya bucket itu sendiri, TANPA `/*`: `ListBucket` adalah tindakan atas
  # bucket, bukan atas objek — DEPLOYMENT.md §9.5.
  statement {
    sid       = "PeriksaKeberadaanBerkas"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.rapor.arn]
  }
}

resource "aws_iam_role_policy" "lambda_api" {
  name   = "edutrack-lambda-api"
  role   = aws_iam_role.lambda_api.id
  policy = data.aws_iam_policy_document.lambda_api.json
}

# --- Fungsi migrate ---------------------------------------------------------

resource "aws_iam_role" "lambda_migrate" {
  name               = "edutrack-lambda-migrate"
  assume_role_policy = data.aws_iam_policy_document.boleh_dipinjam_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_migrate_vpc" {
  role       = aws_iam_role.lambda_migrate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_migrate" {
  # HANYA rahasia pemilik, dan ARN-nya dibaca dari RDS alih-alih ditulis
  # tangan: namanya dibangkitkan RDS beserta akhiran acak, sehingga tidak dapat
  # disepakati di muka maupun ditulis sebagai pola — CK-D-06.
  statement {
    sid       = "BacaKredensialPemilik"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.ini.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "DekripsiRahasia"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.via_secretsmanager]
    }
  }
}

resource "aws_iam_role_policy" "lambda_migrate" {
  name   = "edutrack-lambda-migrate"
  role   = aws_iam_role.lambda_migrate.id
  policy = data.aws_iam_policy_document.lambda_migrate.json
}

# --- NAT instance -----------------------------------------------------------

data "aws_iam_policy_document" "boleh_dipinjam_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nat" {
  name               = "edutrack-nat"
  assume_role_policy = data.aws_iam_policy_document.boleh_dipinjam_ec2.json
}

# Satu-satunya izin instance ini, dan gunanya menghilangkan kebutuhan kunci SSH
# — DEPLOYMENT.md §9.5. Kunci SSH yang tidak ada tidak dapat bocor.
resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "edutrack-nat"
  role = aws_iam_role.nat.name
}
