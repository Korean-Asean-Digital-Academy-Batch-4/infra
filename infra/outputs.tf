# Nama yang disepakati dua sistem diterbitkan sebagai output, dan workflow
# membacanya dari sini alih-alih menuliskannya ulang — DEPLOYMENT.md §2.4.
# Salah ketik di salah satunya menghasilkan rilis yang gagal tanpa petunjuk.

output "nama_fungsi_api" {
  description = "Nama fungsi aplikasi — DEPLOYMENT.md §2.4."
  value       = aws_lambda_function.api.function_name
}

output "nama_fungsi_migrate" {
  description = "Nama fungsi migrasi — DEPLOYMENT.md §2.4."
  value       = aws_lambda_function.migrate.function_name
}

output "nama_alias" {
  description = "Alias rilis. Memindahkannya adalah tindakan rilis itu sendiri."
  value       = aws_lambda_alias.live.name
}

output "role_oidc_backend" {
  description = "ARN role yang dipinjam deploy.yml. Diisikan ke secret AWS_ROLE_ARN."
  value       = aws_iam_role.gha_backend.arn
}

output "role_oidc_frontend" {
  description = "ARN role frontend, atau kosong selama `sub`-nya belum diketahui."
  value       = one(aws_iam_role.gha_frontend[*].arn)
}

# --- Alamat -----------------------------------------------------------------

output "domain_cloudfront" {
  description = <<-EOT
    Satu-satunya alamat yang dapat dihubungi publik. Selama domain sendiri belum
    dibeli (CK-17), inilah alamat yang dipakai — termasuk oleh langkah 11 pada
    DEPLOYMENT.md §3.3.
  EOT
  value       = "https://${aws_cloudfront_distribution.ini.domain_name}"
}

output "id_distribusi" {
  description = "Dipakai pipeline frontend untuk invalidasi."
  value       = aws_cloudfront_distribution.ini.id
}

output "url_fungsi_api" {
  description = <<-EOT
    Function URL. Tidak dapat dipakai siapa pun secara langsung — auth type
    AWS_IAM menolak request yang tidak bertanda tangan SigV4 dari distribusi
    yang ditunjuk. Diterbitkan untuk penelusuran, bukan untuk dipanggil.
  EOT
  value       = aws_lambda_function_url.api.function_url
}

# --- Penyimpanan ------------------------------------------------------------

output "bucket_rapor" {
  description = "Bucket berkas rapor. Privat; akses hanya lewat presigned URL 5 menit."
  value       = aws_s3_bucket.rapor.id
}

output "bucket_frontend" {
  description = "Bucket hasil `vite build`. Privat; dibaca CloudFront lewat OAC."
  value       = aws_s3_bucket.frontend.id
}

# --- Basis data dan rahasia -------------------------------------------------

output "inang_rds" {
  description = "Alamat instance RDS. Hanya dapat dihubungi dari subnet privat-app."
  value       = aws_db_instance.ini.address
}

output "arn_rahasia_owner" {
  description = <<-EOT
    ARN rahasia terkelola RDS berisi kredensial `edutrack_owner` — CK-D-06.
    Namanya dibangkitkan RDS, sehingga ARN inilah satu-satunya cara menunjuknya.
    Dipakai menyambung ke PostgreSQL untuk membuat role app_rw dan app_ro pada
    langkah pengisian rahasia — DEPLOYMENT.md §5.1.
  EOT
  value       = aws_db_instance.ini.master_user_secret[0].secret_arn
}

output "arn_rahasia_app_rw" {
  description = "Wadah rahasia app_rw. Isinya dimasukkan manusia — DEPLOYMENT.md §5.1."
  value       = aws_secretsmanager_secret.app_rw.arn
}

output "arn_rahasia_app_ro" {
  description = "Wadah rahasia app_ro. Isinya dimasukkan manusia — DEPLOYMENT.md §5.1."
  value       = aws_secretsmanager_secret.app_ro.arn
}

# --- Jaringan ---------------------------------------------------------------

output "id_instance_nat" {
  description = <<-EOT
    Dipakai membuka sesi tanpa SSH:

      aws ssm start-session --target <id>
  EOT
  value       = aws_instance.nat.id
}

output "alamat_keluar" {
  description = <<-EOT
    Alamat IPv4 yang terlihat layanan luar, yaitu Elice AI Cloud. Diperlukan
    apabila kelak ada daftar izin di sisi penyedia.
  EOT
  value       = aws_eip.nat.public_ip
}
