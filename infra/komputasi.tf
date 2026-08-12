# ---------------------------------------------------------------------------
# Fungsi Lambda — ARCHITECTURE.md Pasal 6, DEPLOYMENT.md §2.1 dan §2.2
#
# Terraform memiliki CANGKANG: memori, batas waktu, arsitektur, execution role,
# pengaturan VPC, variabel lingkungan, reserved concurrency, Function URL, dan
# keberadaan alias. CI memiliki ISI: `image_uri`, version yang diterbitkan, dan
# ke mana alias `live` menunjuk — CK-D-02.
# ---------------------------------------------------------------------------

data "aws_ecr_repository" "app" {
  name = var.nama_ecr
}

locals {
  # Tag `:bootstrap` sengaja dipilih agar tampak sementara — DEPLOYMENT.md §2.3.
  # Ia hanya dipakai pada pembuatan pertama; sesudah itu `ignore_changes`
  # menjadikannya tidak berpengaruh sama sekali.
  image_bootstrap = "${data.aws_ecr_repository.app.repository_url}:bootstrap"

  # Tetapan yang sama bagi kedua fungsi. `AWS_REGION` TIDAK disetel di sini:
  # Lambda menyediakannya sendiri, dan menyetelnya menghasilkan galat
  # "reserved key" pada saat fungsi dibuat.
  lingkungan_bersama = {
    LINGKUNGAN = "aws"
    DB_INANG   = aws_db_instance.ini.address
    DB_PORTA   = tostring(aws_db_instance.ini.port)
    DB_NAMA    = var.nama_basis_data
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.nama_fungsi_api}"
  retention_in_days = var.retensi_log_hari
}

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/aws/lambda/${var.nama_fungsi_migrate}"
  retention_in_days = var.retensi_log_hari
}

# --- Fungsi api -------------------------------------------------------------

resource "aws_lambda_function" "api" {
  function_name = var.nama_fungsi_api
  role          = aws_iam_role.lambda_api.arn

  package_type  = "Image"
  image_uri     = local.image_bootstrap
  architectures = ["arm64"]
  memory_size   = var.memori_lambda_mb
  timeout       = var.batas_waktu_api_detik

  # Version diterbitkan CI, bukan Terraform. Dengan `publish = true`, penomoran
  # version menjadi rebutan dua sistem — DEPLOYMENT.md §2.2.
  publish = false

  # -1 berarti tidak menyetel reservasi sama sekali — CK-A-11. Remnya berpindah
  # ke plafon concurrency akun, yang justru lebih ketat daripada 40 tetapi tidak
  # tertulis di repositori mana pun. Lihat pemicu peninjauan pada variables.tf.
  reserved_concurrent_executions = var.concurrency_api

  vpc_config {
    subnet_ids         = aws_subnet.privat_app[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.lingkungan_bersama, {
      # Fungsi ini TIDAK menerima RAHASIA_OWNER, dan ketiadaannya bukan
      # kelalaian — DEPLOYMENT.md §9.5. IAM sudah menolaknya; variabel yang
      # tidak ada menutup jalur kedua, yaitu kekeliruan yang menyalinnya ke sini
      # tanpa sadar.
      RAHASIA_APP_RW     = aws_secretsmanager_secret.app_rw.name
      RAHASIA_APP_RO     = aws_secretsmanager_secret.app_ro.name
      PARAMETER_KUNCI_AI = var.parameter_kunci_ai
      BUCKET_RAPOR       = aws_s3_bucket.rapor.id
      ELICE_BASE_URL     = var.elice_base_url
      ELICE_MODEL        = var.elice_model
    })
  }

  lifecycle {
    # image_uri dimiliki CI. Lihat DEPLOYMENT.md Pasal 3 dan CK-D-02.
    ignore_changes = [image_uri]
  }

  depends_on = [aws_cloudwatch_log_group.api]
}

resource "aws_lambda_alias" "live" {
  name             = var.nama_alias
  function_name    = aws_lambda_function.api.function_name
  function_version = "$LATEST" # hanya dipakai saat pembuatan pertama — CK-D-07

  lifecycle {
    # Ke mana alias menunjuk dimiliki CI. Ini tindakan rilis itu sendiri.
    #
    # DUA `ignore_changes`, bukan satu. Melupakan yang ini menghasilkan
    # kegagalan yang lebih buruk daripada melupakan yang pertama: `apply` untuk
    # urusan yang sama sekali tidak berhubungan akan mengembalikan alias ke
    # image bootstrap, dan seluruh aplikasi lenyap — DEPLOYMENT.md §2.2.
    ignore_changes = [function_version]
  }
}

# Auth type AWS_IAM: hanya menerima request bertanda tangan SigV4 dari
# distribusi CloudFront yang ditunjuk. URL yang bocor tidak dapat dipakai siapa
# pun — ARCHITECTURE.md Pasal 2.
resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  qualifier          = aws_lambda_alias.live.name
  authorization_type = "AWS_IAM"

  # `buffered`, bukan `RESPONSE_STREAM`. Respons besar tidak pernah terjadi:
  # berkas rapor dikembalikan sebagai presigned URL, bukan sebagai isi respons
  # — ARCHITECTURE.md Pasal 6 dan 11.
  invoke_mode = "BUFFERED"
}

# --- Fungsi migrate ---------------------------------------------------------

resource "aws_lambda_function" "migrate" {
  function_name = var.nama_fungsi_migrate
  role          = aws_iam_role.lambda_migrate.arn

  package_type  = "Image"
  image_uri     = local.image_bootstrap
  architectures = ["arm64"]
  memory_size   = var.memori_lambda_mb
  timeout       = var.batas_waktu_migrate_detik

  publish = false

  # Semula 1, supaya pemanggilan kedua ditolak seketika alih-alih menunggu kunci
  # sampai batas waktu habis. Dicabut oleh CK-A-11: reservasi sebesar 1 pun
  # ditolak selama plafon concurrency akun masih rendah. Yang mencegah migrasi
  # berbarengan kini hanya advisory lock di dalam penerap.
  reserved_concurrent_executions = var.concurrency_migrate

  vpc_config {
    subnet_ids         = aws_subnet.privat_app[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.lingkungan_bersama, {
      # Satu variabel yang membedakan kedua fungsi — CK-D-08. Perintah image-nya
      # sama persis, dan `image_config` sengaja dibiarkan kosong: ia bagian dari
      # cangkang, sehingga berlaku pula bagi image `:bootstrap` yang dipakai saat
      # fungsi ini dibuat.
      PERAN = "migrasi"

      # Fungsi ini dipanggil `lambda:InvokeFunction` biasa, bukan lewat HTTP.
      # Adapter meneruskan payload invocation semacam itu sebagai POST ke jalur
      # ini. Disetel terang-terangan alih-alih mengandalkan bawaan `/events`,
      # supaya yang dilayani aplikasi dan yang dikirim adapter tertulis pada
      # tempat yang sama-sama terbaca.
      AWS_LWA_PASS_THROUGH_PATH = "/migrasi"

      # ARN, bukan nama. Nama rahasia terkelola RDS dibangkitkan beserta akhiran
      # acak sehingga tidak dapat disepakati di muka — CK-D-06.
      RAHASIA_OWNER = aws_db_instance.ini.master_user_secret[0].secret_arn
    })
  }

  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [aws_cloudwatch_log_group.migrate]
}

# Fungsi `migrate` TIDAK memiliki Function URL, dan tidak boleh memilikinya.
# Ia dipanggil `lambda:InvokeFunction` oleh pipeline (DEPLOYMENT.md §3.3 langkah
# 6), dan tidak pernah dari internet.
