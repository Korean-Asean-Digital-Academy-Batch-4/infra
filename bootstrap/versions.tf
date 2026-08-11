terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }

  # Backend sengaja DIBIARKAN LOKAL pada apply pertama.
  #
  # Konfigurasi ini yang membuat bucket state-nya sendiri, sehingga ia tidak
  # dapat menyimpan state di tempat yang belum ada. Sesudah apply pertama
  # berhasil, blok di bawah dinyalakan lalu state-nya dipindahkan:
  #
  #   terraform init -migrate-state
  #
  # Langkah itu dijelaskan pada README.md dan hanya dikerjakan sekali seumur
  # proyek.
  #
  # backend "s3" {
  #   bucket       = "edutrack-tfstate-<ID-AKUN>"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "ap-southeast-3"
  #   encrypt      = true
  #   use_lockfile = true
  # }
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
