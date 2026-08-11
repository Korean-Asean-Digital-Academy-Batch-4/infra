# Keempat nama pada DEPLOYMENT.md §2.4 diterbitkan sebagai output, dan
# workflow membacanya dari sini alih-alih menuliskannya ulang. Dua di antaranya
# lahir di sini; dua sisanya pada `infra/`.

output "nama_bucket_state" {
  description = "Bucket penyimpan state Terraform. Diisikan ke blok backend pada versions.tf."
  value       = aws_s3_bucket.state.id
}

output "nama_ecr" {
  description = "Nama repositori ECR — DEPLOYMENT.md §2.4."
  value       = aws_ecr_repository.app.name
}

output "url_ecr" {
  description = "URL repositori ECR, dipakai saat mendorong image :bootstrap."
  value       = aws_ecr_repository.app.repository_url
}

output "id_akun" {
  description = "ID akun AWS. Dipakai menyusun ARN pada infra/ dan trust policy OIDC."
  value       = data.aws_caller_identity.ini.account_id
}
