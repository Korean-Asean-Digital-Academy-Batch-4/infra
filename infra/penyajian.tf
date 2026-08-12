# ---------------------------------------------------------------------------
# Penyimpanan berkas dan penyajian — ARCHITECTURE.md Pasal 2, 3, dan 11
#
# Satu domain, dua origin. CloudFront membagi trafik berdasarkan path, sehingga
# CORS hilang seluruhnya dan cookie sesi dapat memakai HttpOnly.
# ---------------------------------------------------------------------------

locals {
  # Nama bucket bersifat unik sedunia. Tidak ada rahasia pada ID akun: ia sudah
  # tercetak pada setiap ARN yang dipakai sehari-hari.
  nama_bucket_rapor    = "edutrack-rapor-${data.aws_caller_identity.ini.account_id}"
  nama_bucket_frontend = "edutrack-frontend-${data.aws_caller_identity.ini.account_id}"
}

# --- Bucket rapor -----------------------------------------------------------

resource "aws_s3_bucket" "rapor" {
  bucket = local.nama_bucket_rapor

  # `destroy` menolak bucket yang masih berisi objek, dan penolakan itu muncul
  # di tengah pembongkaran ketika sebagian sumber daya sudah hilang. Dibuka
  # hanya bersama `izinkan_hapus`; sehari-hari nilainya `false`, sehingga
  # `apply` yang keliru tetap tidak dapat mengosongkan bucket ini.
  #
  # Berkas PDF di dalamnya dapat dirender ulang dari salinan beku `rapor_mapel`
  # yang ikut terbawa `pg_dump`, sehingga yang hilang hanya hasil perhitungan,
  # bukan sumbernya.
  force_destroy = var.izinkan_hapus

  # Berkas rapor adalah satu-satunya turunan yang tidak dapat dihitung ulang
  # apabila salinan bekunya ikut hilang — DEPLOYMENT.md §2.5.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "rapor" {
  bucket = aws_s3_bucket.rapor.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rapor" {
  bucket = aws_s3_bucket.rapor.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "rapor" {
  bucket = aws_s3_bucket.rapor.id

  # Arsip ZIP unduhan sekelas TIDAK PERNAH dipakai ulang — ARCHITECTURE.md
  # Pasal 11. Setiap unduhan menyusunnya kembali dari berkas yang sudah ada,
  # murni pekerjaan I/O tanpa render. Menyimpannya berarti membayar penyimpanan
  # untuk sesuatu yang tidak akan pernah dibaca lagi.
  rule {
    id     = "hapus-arsip-zip"
    status = "Enabled"

    filter {
      prefix = "arsip/"
    }

    expiration {
      days = var.umur_arsip_zip_hari
    }
  }

  # Unggahan multipart yang gagal di tengah tidak terlihat pada daftar objek,
  # tetapi tetap ditagih.
  rule {
    id     = "bersihkan-multipart-gagal"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bucket rapor tidak dapat dihubungi CloudFront maupun siapa pun secara
# langsung. Aksesnya hanya lewat presigned URL berumur 5 menit yang diterbitkan
# aplikasi sesudah kewenangannya diperiksa — ARCHITECTURE.md §11.1.
resource "aws_s3_bucket_policy" "rapor_wajib_tls" {
  bucket = aws_s3_bucket.rapor.id
  policy = data.aws_iam_policy_document.rapor_wajib_tls.json
}

data "aws_iam_policy_document" "rapor_wajib_tls" {
  statement {
    sid       = "TolakTanpaTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.rapor.arn, "${aws_s3_bucket.rapor.arn}/*"]

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

# --- Bucket frontend --------------------------------------------------------

resource "aws_s3_bucket" "frontend" {
  bucket = local.nama_bucket_frontend

  # Isinya seluruhnya hasil `vite build` dan dapat disusun ulang kapan saja,
  # sehingga di sini tidak ada yang perlu dijaga selain menghindari kegagalan
  # `destroy` di tengah jalan.
  force_destroy = var.izinkan_hapus
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bucket privat, hanya dapat dibaca CloudFront lewat Origin Access Control —
# ARCHITECTURE.md Pasal 3. Bukan website hosting, dan bukan bucket publik.
data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "BacaLewatCloudFrontSaja"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.ini.arn]
    }
  }

  statement {
    sid       = "TolakTanpaTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]

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

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}

# --- Origin Access Control --------------------------------------------------

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "edutrack-frontend"
  description                       = "OAC menuju bucket frontend privat"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = "edutrack-api"
  description                       = "OAC menuju Function URL beraut AWS_IAM"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- Kebijakan yang dipakai perilaku ---------------------------------------

data "aws_cloudfront_cache_policy" "tanpa_cache" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimal" {
  name = "Managed-CachingOptimized"
}

# WAJIB bagi origin berupa Function URL. Function URL menolak request yang
# header Host-nya menunjuk CloudFront alih-alih dirinya sendiri, dan penolakan
# itu berbentuk 403 yang tidak menyebutkan Host sama sekali. Kebijakan ini
# meneruskan seluruh header, cookie, dan query string KECUALI Host.
data "aws_cloudfront_origin_request_policy" "semua_kecuali_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_response_headers_policy" "keamanan" {
  name    = "edutrack-keamanan"
  comment = "HSTS, nosniff, Referrer-Policy, dan CSP - ARCHITECTURE.md Pasal 12"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    content_security_policy {
      # `connect-src 'self'` cukup karena frontend dan backend berada pada satu
      # domain — ARCHITECTURE.md Pasal 3. Tidak ada satu pun origin luar yang
      # perlu didaftar, dan tidak ada CDN pihak ketiga.
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'"
      override                = true
    }
  }
}

# --- Distribusi -------------------------------------------------------------

resource "aws_cloudfront_distribution" "ini" {
  enabled             = true
  comment             = "EduTrack - satu domain, dua origin"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  http_version        = "http2and3"
  is_ipv6_enabled     = true

  origin {
    origin_id                = "frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    origin_id = "api"
    # `function_url` berbentuk `https://<id>.lambda-url.<region>.on.aws/`,
    # sedangkan origin CloudFront menuntut nama host telanjang.
    domain_name              = trimsuffix(trimprefix(aws_lambda_function_url.api.function_url, "https://"), "/")
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      # Batas waktu fungsi 30 detik; origin diberi kelonggaran satu detik
      # supaya yang melaporkan kegagalan adalah aplikasi, bukan CloudFront.
      origin_read_timeout = 31
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.optimal.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.keamanan.id
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Tanpa cache sama sekali. Seluruh jalur /api/* bergantung pada cookie sesi,
    # dan jawaban yang ter-cache akan disajikan kepada pengguna yang salah.
    cache_policy_id            = data.aws_cloudfront_cache_policy.tanpa_cache.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.semua_kecuali_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.keamanan.id
  }

  # TIDAK ADA `custom_error_response`, dan ketiadaannya disengaja.
  #
  # Blok itu semula dipasang untuk perutean React SPA: setiap path yang bukan
  # berkas dilayani `/index.html`. Ia dicabut karena **berlaku se-distribusi,
  # bukan per-behavior** — CloudFront tidak mengenal error response per
  # perilaku. Akibatnya setiap 403 dan 404 dari `/api/*` ikut dibelokkan ke
  # `/index.html`, sehingga:
  #
  #   - kontrak API rusak: 404 berubah menjadi 200 berisi HTML, dan amplop
  #     `kesalahan` pada API.md §2 tidak pernah sampai ke pemanggil
  #   - galat yang sesungguhnya tertutup, karena yang terlihat justru jawaban
  #     bucket frontend
  #
  # Perutean SPA diselesaikan kelak lewat CloudFront Function pada perilaku
  # bawaan saja, ketika repositori frontend ada. Sampai saat itu, deep link
  # yang dimuat ulang menjawab 403 dari S3 — dan tidak ada satu pun yang
  # memakainya, karena frontend-nya belum ada.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Domain bawaan CloudFront, tanpa alias. Nama domain sengaja dikerjakan
  # paling akhir (CK-17); penambahan `aliases` beserta `acm_certificate_arn`
  # dari provider us_east_1 tidak membongkar satu pun sumber daya di atas.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Function URL beraut AWS_IAM hanya menerima request bertanda tangan SigV4 dari
# distribusi yang ditunjuk — ARCHITECTURE.md §12.
#
# ⚠️ DUA IZIN, BUKAN SATU. Ini yang paling mudah terlewat, dan gejalanya adalah
# 403 pada setiap request — termasuk `GET` tanpa body — dengan kebijakan yang
# tampak persis benar di layar.
#
# `lambda:InvokeFunctionUrl` saja tidak cukup: CloudFront juga memerlukan
# `lambda:InvokeFunction`. Dokumentasi OAC AWS menyebutkan keduanya sebagai dua
# perintah `add-permission` terpisah, dan yang kedua mudah terbaca sebagai
# pengulangan yang pertama.
#
# Ditemukan 12 Agustus 2026 setelah lima `apply`. Yang menyesatkan: pengujian
# dengan kredensial manusia lolos, karena role `edutrack-terraform`
# ber-AdministratorAccess sehingga memiliki KEDUA izin — sementara principal
# CloudFront hanya memiliki yang pertama.

resource "aws_lambda_permission" "cloudfront" {
  statement_id  = "IzinkanCloudFront"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.ini.arn

  # `function_url_auth_type` TIDAK disetel. Menyetelnya membuat Terraform
  # menambahkan syarat `lambda:FunctionUrlAuthType = AWS_IAM`, dan contoh
  # kebijakan OAC pada dokumentasi AWS tidak memuatnya. Yang menegakkan auth
  # type berada di tempat lain: `aws_lambda_function_url.api`.
}

resource "aws_lambda_permission" "cloudfront_invoke" {
  statement_id  = "IzinkanCloudFrontInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.ini.arn
}

