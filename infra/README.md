# `infra/` — seluruh infrastruktur selain bootstrap

| Keterangan | Isi |
|---|---|
| **Tahap** | **B3** dan **B5** — [AGENTS.md §8.2](../../context/AGENTS.md) |
| **Kedudukan** | Catatan pemakaian. Ketentuannya pada [DEPLOYMENT.md Pasal 2 dan 9](../../context/DEPLOYMENT.md) dan [ARCHITECTURE.md Pasal 2, 6, 11, dan 12](../../context/ARCHITECTURE.md) |
| **`apply` dijalankan oleh** | **Manusia.** Peminjaman role menuntut kode MFA — [AGENTS.md §10](../../context/AGENTS.md) |

## Prasyarat

| # | Yang harus sudah ada | Dari |
|:--:|---|---|
| 1 | Bucket state dan repositori ECR | `terraform apply` pada [`../bootstrap/`](../bootstrap/) — **B1, sudah selesai** |
| 2 | Image `edutrack:bootstrap` sudah didorong | [`../bootstrap-image/`](../bootstrap-image/) — **B2** |
| 3 | Nilai `elice_base_url` | Halaman model Elice. Bukan rahasia; kuncinya yang rahasia |

Tanpa nomor 2, `apply` gagal pada pembuatan fungsi Lambda dengan keluhan image yang tidak ditemukan — sesudah VPC, RDS, dan CloudFront terlanjur dibuat.

## Menjalankan

Terraform **tidak dapat memakai `AWS_PROFILE`** di sini, dan itu bukan salah konfigurasi — [DEPLOYMENT.md §9.6](../../context/DEPLOYMENT.md). Sesi yang sudah dipinjam CLI diserahkan sebagai variabel lingkungan:

```bash
eval "$(aws configure export-credentials --profile edutrack --format env)"
```

Sesinya berumur 4 jam. Sesudah itu perintah di atas diulang.

```bash
terraform -chdir=infra init
```

Nilai `elice_base_url` tidak memiliki bawaan. Taruh pada `infra/terraform.tfvars`, yang sudah tercantum pada `.gitignore`:

```bash
printf 'elice_base_url = "https://mlapi.run/<id-endpoint>"\n' > infra/terraform.tfvars
```

```bash
terraform -chdir=infra plan -out=rencana.tfplan
```

**Bacalah rencananya sebelum menerapkannya.** `apply` pertama membuat sekitar lima puluh sumber daya, dan RDS mulai menagih sejak menyala.

```bash
terraform -chdir=infra apply rencana.tfplan
```

Perkiraan lama: **20–25 menit**, dan hampir seluruhnya CloudFront serta RDS.

## Satu langkah yang wajib mendahului `apply` — B5

Role `edutrack-gha-backend` **sudah ada**. Ia dibuat dengan tangan lewat konsol pada B0.5, dan jabat tangannya sudah terbukti ([Gitaction.md](../../context/Gitaction.md)). Terraform harus mengambil alih role itu, bukan membuatnya:

```bash
terraform -chdir=infra import aws_iam_role.gha_backend edutrack-gha-backend
```

Dijalankan **sesudah `init` dan sebelum `apply`**. Melewatinya membuat `apply` gagal dengan `EntityAlreadyExists` — kegagalan yang aman. Yang tidak aman adalah menghapus role itu lebih dahulu supaya "bersih": OIDC provider akan kehilangan sasaran kepercayaannya, dan gejalanya baru muncul pada rilis pertama.

Sesudah import, `plan` akan menunjukkan perubahan pada trust policy-nya. Itu wajar dan memang dikehendaki: yang tertulis pada [`iam-oidc.tf`](iam-oidc.tf) adalah bentuk yang sama, kini dipelihara Terraform.

## Sesudah `apply` — urutan yang mengikat

| # | Langkah | Tercatat pada |
|:--:|---|---|
| 1 | Isi kedua rahasia `app_rw` dan `app_ro`, dan buat kedua role di PostgreSQL | [DEPLOYMENT.md §5.1](../../context/DEPLOYMENT.md) |
| 2 | Isi parameter SSM kunci Elice | [DEPLOYMENT.md §5.1](../../context/DEPLOYMENT.md) |
| 3 | Buktikan penandatanganan OAC atas request ber-body — **B4** | [`../uji-oac/`](../uji-oac/) |
| 4 | Setel secret `AWS_ROLE_ARN` pada repositori backend dari output `role_oidc_backend` | [DEPLOYMENT.md §9.4](../../context/DEPLOYMENT.md) |
| 5 | Rilis pertama lewat `deploy.yml` — **B6** | [DEPLOYMENT.md §3.3](../../context/DEPLOYMENT.md) |

Langkah 1 menuntut sambungan ke RDS, sedangkan RDS berada di subnet privat tanpa jalan masuk dari luar. Jalurnya lewat NAT instance sebagai perantara, tanpa SSH:

```bash
aws ssm start-session --target "$(terraform -chdir=infra output -raw id_instance_nat)" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "{\"host\":[\"$(terraform -chdir=infra output -raw inang_rds)\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
```

Kata sandi masternya dibaca dari rahasia terkelola RDS, yang ARN-nya diterbitkan sebagai output `arn_rahasia_owner` (CK-D-06).

## Yang TIDAK dikelola berkas-berkas ini

| Yang tidak dikelola | Sebab |
|---|---|
| Isi rahasia Secrets Manager | Nilainya akan masuk ke state — CK-D-05 |
| Parameter SSM, termasuk wadahnya | `aws_ssm_parameter` mewajibkan `value` — CK-D-05 |
| Kata sandi master RDS | Dibangkitkan, disimpan, dan dirotasi RDS sendiri — CK-D-06 |
| `image_uri` kedua fungsi | Dimiliki CI — CK-D-02 |
| Ke mana alias `live` menunjuk | Dimiliki CI. Memindahkannya adalah tindakan rilis itu sendiri |
| Role `edutrack-readonly` | Belum ada. Dibuat manusia lewat konsol bersama sisa B0 |
| Role `edutrack-gha-frontend` | Nilai `sub`-nya belum diketahui — lihat `variables.tf` |
| Alias domain dan sertifikat ACM | Domain sengaja dikerjakan paling akhir — CK-17 |

## Deteksi drift

Terraform berhenti mengawasi `image_uri` dan `function_version` — **bukan berhenti mengawasi sisanya** ([DEPLOYMENT.md §2.6](../../context/DEPLOYMENT.md)). Perubahan memori, security group, atau aturan bucket lewat konsol tetap merupakan drift sungguhan:

```bash
terraform -chdir=infra plan -detailed-exitcode
```

Keluar `0` berarti tidak ada selisih, `2` berarti ada. Dijalankan pada setiap pull request infrastruktur dan terjadwal seminggu sekali.

## Yang dilindungi dari penghapusan

`prevent_destroy` terpasang pada **RDS** dan **bucket rapor** (ECR dilindungi di `bootstrap/`) — [DEPLOYMENT.md §2.5](../../context/DEPLOYMENT.md). RDS memiliki lapis kedua berupa `deletion_protection`, karena keduanya menjaga hal yang berbeda: yang pertama menghentikan Terraform, yang kedua menghentikan siapa pun lewat konsol maupun CLI.

`terraform destroy` atas seluruh konfigurasi ini **akan gagal**, dan itu memang maksudnya.
