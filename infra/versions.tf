terraform {
  # 1.10 atau lebih baru — penguncian state memakai `use_lockfile`, bukan tabel
  # DynamoDB (CK-D-04). `bootstrap/` memakai patokan yang sama.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }

  backend "s3" {
    bucket       = "edutrack-tfstate-274286556151"
    key          = "infra/terraform.tfstate"
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
      Lapisan  = "infra"
    }
  }
}

# Sertifikat ACM untuk CloudFront WAJIB diterbitkan di us-east-1, sedangkan
# seluruh sumber daya lain berada di ap-southeast-3 — ARCHITECTURE.md §12.2
# peringatan pertama, CK-16.
#
# Provider alias ini dideklarasikan sekarang meskipun belum ada satu pun sumber
# daya yang memakainya. Nama domain sengaja dikerjakan paling akhir (CK-17), dan
# menambahkan alias belakangan menuntut penataan ulang berkas ini pada saat yang
# paling tidak tepat: ketika domain baru dibeli dan orang sedang terburu-buru.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Proyek   = "edutrack"
      Dikelola = "terraform"
      Lapisan  = "infra"
    }
  }
}
