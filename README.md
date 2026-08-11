# EduTrack — Infrastruktur

Terraform bagi seluruh infrastruktur AWS EduTrack. Repositori ini adalah
**Jalur B** pada [AGENTS.md §8](../context/AGENTS.md).

| Direktori | Isi | Dijalankan |
|---|---|---|
| [`bootstrap/`](bootstrap/) | Bucket state beserta pengunciannya, repositori ECR | Sekali, di awal |
| `infra/` | Seluruh sisanya: VPC, RDS, Lambda, S3, CloudFront, IAM | Setiap kali infrastruktur berubah |

Alasan pemisahannya, pembagian kepemilikan antara Terraform dan CI, serta
ketentuan `ignore_changes` yang mengikat, seluruhnya pada
[DEPLOYMENT.md §2](../context/DEPLOYMENT.md). **Dokumen mendahului kode**: yang
tertulis di sana berlaku apabila bertentangan dengan apa pun di repositori ini.

## Tiga hal yang paling mudah salah

1. **Dua `ignore_changes`, bukan satu** — `image_uri` pada fungsi *dan*
   `function_version` pada alias. Melupakan yang kedua mengembalikan alias ke
   image bootstrap pada apply yang tampaknya tidak berhubungan (§2.2).
2. **`prevent_destroy` pada ECR, RDS, dan bucket rapor** (§2.5).
3. **`sub` OIDC dipatok ke repositori dan ref sekaligus.** Organisasi ini
   memakai custom subject claim, sehingga nilainya bukan format baku — lihat
   [Gitaction.md](../context/Gitaction.md).

## Menjalankan

```bash
eval "$(aws configure export-credentials --profile edutrack --format env)"
```

```bash
terraform -chdir=bootstrap apply
```

Peminjaman role menuntut kode MFA dari ponsel, dan **Terraform tidak dapat
menanyakannya sendiri** — karena itu sesinya diserahkan lewat variabel
lingkungan, bukan lewat `AWS_PROFILE`. Sebabnya pada
[DEPLOYMENT.md §9.6](../context/DEPLOYMENT.md). Agen tidak dapat menjalankan
langkah ini — [AGENTS.md §10](../context/AGENTS.md).
