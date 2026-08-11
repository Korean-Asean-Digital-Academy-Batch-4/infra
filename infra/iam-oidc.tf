# ---------------------------------------------------------------------------
# Role mesin — DEPLOYMENT.md §9.4. Tahap B5.
#
# Dipinjam GitHub Actions lewat OIDC. Tidak ada access key, dan tidak ada IAM
# user. Token berumur satu kali jalan.
#
# ⚠️ Role `edutrack-gha-backend` SUDAH ADA — dibuat dengan tangan lewat konsol
# pada B0.5, dan jabat tangannya sudah terbukti (Gitaction.md). Ia karenanya
# di-IMPORT, bukan dibuat ulang:
#
#   terraform -chdir=infra import aws_iam_role.gha_backend edutrack-gha-backend
#
# Membuat ulang berarti menghapus role yang sedang dipercaya OIDC provider, dan
# jabat tangan yang sudah terbukti akan putus tanpa gejala sampai rilis pertama.
# ---------------------------------------------------------------------------

# Satu OIDC provider per akun, dipakai bersama kedua role — DEPLOYMENT.md §9.4.
# Dibaca, bukan dibuat: ia sudah didaftarkan pada B0.5.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "boleh_dipinjam_gha_backend" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, bukan StringLike, dan nilainya utuh sampai ke ref. Menulis
    # `repo:<ORG>/*` membuat repositori mana pun di organisasi itu dapat
    # menerapkan ke produksi — kekeliruan OIDC yang paling sering terjadi, dan
    # tidak menimbulkan gejala apa pun sampai disalahgunakan.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [var.sub_oidc_backend]
    }
  }
}

resource "aws_iam_role" "gha_backend" {
  name               = "edutrack-gha-backend"
  description        = "Dipinjam workflow deploy.yml repositori backend, ref main"
  assume_role_policy = data.aws_iam_policy_document.boleh_dipinjam_gha_backend.json
}

data "aws_iam_policy_document" "gha_backend" {
  # Token login ECR tidak dapat dibatasi pada satu repositori: ia tindakan
  # tingkat registri. Yang dibatasi adalah pendorongannya, pada pernyataan
  # berikutnya.
  statement {
    sid       = "TokenLoginEcr"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "DorongSatuRepositoriEcr"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }

  # Lima tindakan, tidak lebih. Yang justru penting adalah yang TIDAK ada di
  # sini: `CreateFunction`, `UpdateFunctionConfiguration`, `DeleteFunction`, dan
  # `iam:PassRole`.
  #
  # Ketiadaan `iam:PassRole` adalah akibat langsung dari pembagian kepemilikan
  # pada CK-D-02: Terraform memiliki cangkang fungsi, CI hanya menukar isinya.
  # Karena CI tidak pernah membuat maupun mengonfigurasi ulang fungsi, izin
  # paling berbahaya itu dapat dihilangkan sepenuhnya — DEPLOYMENT.md §9.4.
  statement {
    sid    = "RilisDuaFungsi"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
      "lambda:UpdateAlias",
      "lambda:GetFunction",
      "lambda:GetAlias",
      "lambda:InvokeFunction",
    ]
    resources = [
      aws_lambda_function.api.arn,
      "${aws_lambda_function.api.arn}:*",
      aws_lambda_function.migrate.arn,
      "${aws_lambda_function.migrate.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "gha_backend" {
  name   = "edutrack-gha-backend"
  role   = aws_iam_role.gha_backend.id
  policy = data.aws_iam_policy_document.gha_backend.json
}

# --- Role frontend ----------------------------------------------------------
#
# Dibuat hanya apabila nilai `sub`-nya sudah diketahui. Nilai itu baru terbaca
# dari log diagnostik workflow repositori frontend (Gitaction.md), dan
# repositorinya belum ada. Role dengan trust policy yang salah lebih buruk
# daripada role yang belum ada: ia tampak benar di layar dan menolak setiap
# permintaan tanpa petunjuk.

data "aws_iam_policy_document" "boleh_dipinjam_gha_frontend" {
  count = var.sub_oidc_frontend == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [var.sub_oidc_frontend]
    }
  }
}

resource "aws_iam_role" "gha_frontend" {
  count = var.sub_oidc_frontend == "" ? 0 : 1

  name               = "edutrack-gha-frontend"
  description        = "Dipinjam workflow repositori frontend, ref main"
  assume_role_policy = data.aws_iam_policy_document.boleh_dipinjam_gha_frontend[0].json
}

data "aws_iam_policy_document" "gha_frontend" {
  count = var.sub_oidc_frontend == "" ? 0 : 1

  # Bucket frontend saja. Bucket rapor, Lambda, ECR, dan RDS tidak tersentuh —
  # DEPLOYMENT.md §9.4.
  statement {
    sid       = "UnggahBerkasStatis"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
  }

  statement {
    sid       = "DaftarBucketFrontend"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.frontend.arn]
  }

  statement {
    sid       = "InvalidasiSatuDistribusi"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.ini.arn]
  }
}

resource "aws_iam_role_policy" "gha_frontend" {
  count = var.sub_oidc_frontend == "" ? 0 : 1

  name   = "edutrack-gha-frontend"
  role   = aws_iam_role.gha_frontend[0].id
  policy = data.aws_iam_policy_document.gha_frontend[0].json
}
