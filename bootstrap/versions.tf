terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }

  # Bucket ini dibuat oleh konfigurasi ini sendiri pada apply pertama, yang
  # karenanya berjalan dengan backend lokal. Blok di bawah dinyalakan sesudah
  # apply itu berhasil, lalu state-nya dipindahkan sekali seumur proyek:
  #
  #   terraform -chdir=bootstrap init -migrate-state
  #
  # Nama bucket wajib literal — blok backend tidak menerima variabel maupun
  # data source, sehingga ID akun ditulis apa adanya. Ia bukan rahasia: setiap
  # ARN yang dipakai sehari-hari sudah memuatnya.
  backend "s3" {
    bucket       = "edutrack-tfstate-274286556151"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-southeast-3"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Proyek   = "edutrack"
      Dikelola = "terraform"
      Lapisan  = "bootstrap"
    }
  }
}
