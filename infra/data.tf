# ---------------------------------------------------------------------------
# RDS PostgreSQL — Techstack.md §4.1, ARCHITECTURE.md Pasal 2
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "ini" {
  name       = "edutrack"
  subnet_ids = aws_subnet.privat_data[*].id

  description = "Subnet privat-data. Tanpa rute keluar sama sekali."
}

resource "aws_db_parameter_group" "ini" {
  # `name_prefix`, bukan `name`. Perubahan yang menuntut penggantian parameter
  # group akan membuat yang baru lebih dahulu (`create_before_destroy`), dan
  # nama tetap membuat langkah itu gagal karena namanya masih terpakai.
  name_prefix = "edutrack-postgres${var.versi_postgres}-"
  family      = "postgres${var.versi_postgres}"
  description = "Menegakkan TLS pada seluruh koneksi"

  # Adapter menyusun URL dengan `sslmode=require`; parameter ini membuat
  # koneksi tanpa TLS ditolak basis datanya sendiri, bukan hanya tidak diminta
  # kliennya. Bentuknya sama dengan Prinsip 4 ARCHITECTURE.md: yang dapat
  # dijamin secara struktural tidak diserahkan kepada ingatan orang.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "ini" {
  identifier     = "edutrack"
  engine         = "postgres"
  engine_version = var.versi_postgres
  instance_class = var.kelas_rds

  db_name  = var.nama_basis_data
  username = var.pengguna_master

  # CK-D-06. Kata sandi master dibangkitkan, disimpan, dan dirotasi RDS sendiri;
  # ia tidak pernah melewati Terraform, tidak pernah melewati mesin siapa pun,
  # dan karenanya tidak pernah masuk ke berkas state — Techstack.md §7 butir 1.
  manage_master_user_password = true

  allocated_storage     = var.penyimpanan_rds_gb
  max_allocated_storage = 0 # tanpa autoscaling — volumenya kecil dan tetap
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.ini.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.ini.name
  port                   = 5432

  backup_retention_period = var.retensi_cadangan_hari
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = false

  # Penghapusan basis data berisi nilai satu sekolah tidak boleh mungkin terjadi
  # sebagai akibat sampingan sebuah `apply` — DEPLOYMENT.md §2.5. Dua lapis,
  # karena keduanya menjaga hal yang berbeda: `prevent_destroy` menghentikan
  # Terraform, `deletion_protection` menghentikan siapa pun lewat konsol maupun
  # CLI.
  deletion_protection = true

  skip_final_snapshot       = false
  final_snapshot_identifier = "edutrack-akhir"

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Rahasia — DEPLOYMENT.md §5.1, CK-D-05 dan CK-D-06
#
# Yang dibuat di sini WADAHNYA saja. `aws_secretsmanager_secret_version` tidak
# pernah dipakai: resource itulah yang akan menaruh kata sandi ke dalam state.
# Isinya dimasukkan manusia sesudah RDS menyala, dengan prosedur pada §5.1.
#
# Rahasia ketiga — `edutrack_owner` — tidak ada di sini sama sekali. Ia dibuat
# RDS beserta isinya (CK-D-06), dan ARN-nya dibaca dari `master_user_secret`.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "app_rw" {
  name        = "edutrack/db/app_rw"
  description = "Kredensial app_rw - seluruh jalur tulis aplikasi. Isi dibuat manusia."

  # Tujuh hari, bukan tiga puluh hari bawaan. Nama rahasia yang dihapus tetap
  # terpakai selama masa pemulihan, sehingga membangun ulang lingkungan dalam
  # sebulan akan gagal dengan keluhan nama yang sudah ada.
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret" "app_ro" {
  name        = "edutrack/db/app_ro"
  description = "Kredensial app_ro - jalur AI, tanpa hak tulis. Isi dibuat manusia."

  recovery_window_in_days = 7
}
