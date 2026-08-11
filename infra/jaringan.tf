# ---------------------------------------------------------------------------
# VPC — ARCHITECTURE.md Pasal 2 dan 12
#
# Tidak ada satu pun sumber daya yang dapat dihubungi langsung dari internet.
# Fungsi Lambda berada di subnet privat agar RDS tidak pernah dapat dihubungi
# dari luar; jalur keluarnya lewat NAT instance, dan S3 lewat gateway endpoint
# yang tidak berbiaya.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "ini" {}

locals {
  # Tiga lapis subnet, masing-masing pada dua zona. Pembagiannya mengikuti apa
  # yang boleh dihubungi, bukan sekadar kerapian:
  #
  #   publik      → NAT instance. Satu-satunya yang punya rute ke IGW
  #   privat-app  → ENI Lambda. Keluar lewat NAT, S3 lewat gateway endpoint
  #   privat-data → RDS. TANPA rute keluar sama sekali
  cidr_publik      = [cidrsubnet(var.cidr_vpc, 8, 0), cidrsubnet(var.cidr_vpc, 8, 1)]
  cidr_privat_app  = [cidrsubnet(var.cidr_vpc, 8, 10), cidrsubnet(var.cidr_vpc, 8, 11)]
  cidr_privat_data = [cidrsubnet(var.cidr_vpc, 8, 20), cidrsubnet(var.cidr_vpc, 8, 21)]
}

resource "aws_vpc" "ini" {
  cidr_block           = var.cidr_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "edutrack" }
}

resource "aws_internet_gateway" "ini" {
  vpc_id = aws_vpc.ini.id

  tags = { Name = "edutrack" }
}

resource "aws_subnet" "publik" {
  count = length(var.zona)

  vpc_id            = aws_vpc.ini.id
  cidr_block        = local.cidr_publik[count.index]
  availability_zone = var.zona[count.index]

  tags = { Name = "edutrack-publik-${var.zona[count.index]}" }
}

resource "aws_subnet" "privat_app" {
  count = length(var.zona)

  vpc_id            = aws_vpc.ini.id
  cidr_block        = local.cidr_privat_app[count.index]
  availability_zone = var.zona[count.index]

  tags = { Name = "edutrack-privat-app-${var.zona[count.index]}" }
}

resource "aws_subnet" "privat_data" {
  count = length(var.zona)

  vpc_id            = aws_vpc.ini.id
  cidr_block        = local.cidr_privat_data[count.index]
  availability_zone = var.zona[count.index]

  tags = { Name = "edutrack-privat-data-${var.zona[count.index]}" }
}

# --- Perutean ---------------------------------------------------------------

resource "aws_route_table" "publik" {
  vpc_id = aws_vpc.ini.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ini.id
  }

  tags = { Name = "edutrack-publik" }
}

resource "aws_route_table_association" "publik" {
  # `length(var.zona)`, BUKAN `length(aws_subnet.publik)`. Yang kedua bergantung
  # pada sumber daya yang belum ada, sehingga jumlahnya tidak dapat diketahui
  # saat plan dan Terraform menolak seluruh perintah — termasuk `import` yang
  # tidak berhubungan sama sekali. `terraform validate` tidak menangkap ini.
  count = length(var.zona)

  subnet_id      = aws_subnet.publik[count.index].id
  route_table_id = aws_route_table.publik.id
}

# Satu tabel untuk kedua zona, karena NAT instance-nya memang satu. Tabel per
# zona hanya bermakna apabila ada NAT per zona, dan NAT kedua menambah $7,50
# per bulan untuk ketersediaan yang tidak dituntut satu pun kriteria.
resource "aws_route_table" "privat_app" {
  vpc_id = aws_vpc.ini.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  tags = { Name = "edutrack-privat-app" }
}

resource "aws_route_table_association" "privat_app" {
  count = length(var.zona)

  subnet_id      = aws_subnet.privat_app[count.index].id
  route_table_id = aws_route_table.privat_app.id
}

# TANPA rute keluar. RDS tidak pernah memerlukannya, dan ketiadaannya menutup
# seluruh jalur keluar dari lapis data sekaligus.
resource "aws_route_table" "privat_data" {
  vpc_id = aws_vpc.ini.id

  tags = { Name = "edutrack-privat-data" }
}

resource "aws_route_table_association" "privat_data" {
  count = length(var.zona)

  subnet_id      = aws_subnet.privat_data[count.index].id
  route_table_id = aws_route_table.privat_data.id
}

# --- Gateway endpoint S3 ----------------------------------------------------

# Tidak berbiaya, dan menjadikan unggah maupun unduh berkas rapor tidak melewati
# NAT — ARCHITECTURE.md Pasal 2. Tanpa ini, setiap PDF yang dirender dibayar dua
# kali: sekali sebagai penyimpanan, sekali sebagai lalu lintas NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.ini.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [aws_route_table.privat_app.id]

  tags = { Name = "edutrack-s3" }
}

# --- Security group ---------------------------------------------------------

resource "aws_security_group" "lambda" {
  name        = "edutrack-lambda"
  description = "ENI fungsi Lambda di subnet privat-app"
  vpc_id      = aws_vpc.ini.id

  tags = { Name = "edutrack-lambda" }
}

resource "aws_vpc_security_group_egress_rule" "lambda_keluar" {
  security_group_id = aws_security_group.lambda.id
  description       = "Elice AI Cloud lewat NAT, S3 lewat gateway endpoint"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "rds" {
  name        = "edutrack-rds"
  description = "RDS di subnet privat-data"
  vpc_id      = aws_vpc.ini.id

  tags = { Name = "edutrack-rds" }
}

# Sumbernya security group, BUKAN rentang alamat. Alamat IP ENI Lambda berganti
# setiap kali fungsi diperbarui; keanggotaan security group tidak.
resource "aws_vpc_security_group_ingress_rule" "rds_dari_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL hanya dari fungsi Lambda"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

resource "aws_security_group" "nat" {
  name        = "edutrack-nat"
  description = "NAT instance di subnet publik"
  vpc_id      = aws_vpc.ini.id

  tags = { Name = "edutrack-nat" }
}

# Hanya dari dalam VPC. Tidak ada satu pun aturan masuk dari internet, dan
# tidak ada port 22: pemeliharaannya lewat SSM Session Manager (§9.5).
resource "aws_vpc_security_group_ingress_rule" "nat_dari_vpc" {
  security_group_id = aws_security_group.nat.id
  description       = "Trafik keluar dari subnet privat"
  ip_protocol       = "-1"
  cidr_ipv4         = var.cidr_vpc
}

resource "aws_vpc_security_group_egress_rule" "nat_keluar" {
  security_group_id = aws_security_group.nat.id
  description       = "Jalur keluar menuju internet"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- NAT instance -----------------------------------------------------------

# Amazon Linux 2023 arm64, dibaca dari parameter publik SSM alih-alih dipatok
# sebagai id AMI. Id AMI berbeda per region dan berganti setiap rilis; menuliskan
# yang lama berarti menjalankan sistem tanpa tambalan keamanan.
data "aws_ssm_parameter" "ami_al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ssm_parameter.ami_al2023_arm64.value
  instance_type          = var.jenis_nat
  subnet_id              = aws_subnet.publik[0].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  iam_instance_profile   = aws_iam_instance_profile.nat.name

  # WAJIB. Tanpa ini, VPC membuang paket yang alamat tujuannya bukan instance
  # ini sendiri — yaitu persis seluruh paket yang seharusnya diteruskan.
  source_dest_check = false

  user_data_replace_on_change = true
  user_data                   = <<-BASH
    #!/bin/bash
    set -euo pipefail

    # Penerusan paket dan penyamaran alamat. Ditulis ke berkas konfigurasi,
    # bukan hanya disetel pada memori: instance yang menyala kembali setelah
    # pemeliharaan harus tetap menjadi NAT.
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-nat.conf
    sysctl -p /etc/sysctl.d/99-nat.conf

    dnf install -y iptables-services
    ANTARMUKA=$(ip -o -4 route show to default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o "$ANTARMUKA" -s ${var.cidr_vpc} -j MASQUERADE
    iptables -F FORWARD
    /usr/libexec/iptables/iptables.init save
    systemctl enable --now iptables
  BASH

  metadata_options {
    http_tokens = "required" # IMDSv2 saja
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "edutrack-nat" }
}

# Alamat IPv4 publik ditagih $0,005 per jam entah lekat pada EIP atau tidak
# (Techstack.md §8.3). Yang dibeli EIP di sini adalah kestabilannya: alamat
# yang berganti setiap instance dimulai ulang membuat daftar izin di sisi mana
# pun menjadi tidak berguna.
resource "aws_eip" "nat" {
  domain   = "vpc"
  instance = aws_instance.nat.id

  tags = { Name = "edutrack-nat" }

  depends_on = [aws_internet_gateway.ini]
}
