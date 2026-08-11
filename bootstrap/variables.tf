variable "region" {
  description = "Region AWS. Ditetapkan CK-16 pada Techstack.md."
  type        = string
  default     = "ap-southeast-3"
}

variable "nama_ecr" {
  description = <<-EOT
    Nama repositori ECR. Salah satu dari empat nama yang disepakati Terraform
    dan berkas workflow — DEPLOYMENT.md §2.4. Salah ketik menghasilkan rilis
    yang gagal tanpa petunjuk jelas.
  EOT
  type        = string
  default     = "edutrack"
}

variable "umur_image_tanpa_tag_hari" {
  description = "Umur image tanpa tag sebelum dibersihkan. Image bertag tidak pernah dihapus."
  type        = number
  default     = 14
}
