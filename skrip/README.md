# Membongkar dan membangun kembali lingkungan

Dua skrip yang menjadikan lingkungan AWS EduTrack dapat dilenyapkan dan
didirikan kembali. Alasannya biaya: akun ditagih per jam atas sumber daya yang
berdiri, sedangkan pembuatannya sendiri tidak berbiaya — [DEPLOYMENT.md
CK-D-09](../../context/DEPLOYMENT.md).

| Berkas | Isi |
|---|---|
| [`turunkan.sh`](turunkan.sh) | Cadangkan basis data, lalu bongkar seluruhnya |
| [`naikkan.sh`](naikkan.sh) | Bangun dari nol sampai aplikasi menjawab |
| [`lib-sesi.sh`](lib-sesi.sh) | Sesi MFA, tunnel SSM, sidik jari data — dipakai keduanya |
| [`izinkan-hapus.patch`](izinkan-hapus.patch) | Mencabut `prevent_destroy` dari RDS, bucket rapor, dan ECR |
| [`backend-lokal.patch`](backend-lokal.patch) | Melokalkan backend `bootstrap/` selama bucket state belum ada |

```bash
./skrip/turunkan.sh          # ~35-45 menit
./skrip/naikkan.sh           # ~25-35 menit
```

Keduanya menuntut manusia **tepat dua kali**, dan keduanya memang tidak dapat
diwakilkan: kode MFA dari ponsel, dan kunci API Elice. Seluruh rahasia lain
dibangkitkan — RDS membangkitkan kata sandi masternya sendiri (CK-D-06), dan
`naikkan.sh` membangkitkan kata sandi `app_rw` dan `app_ro`.

## Empat hal yang paling mudah salah

1. **`prevent_destroy` tidak dapat dijadikan variabel.** Terraform melarang
   variabel di dalam blok `lifecycle`, dan berkas overlay juga tidak menolong
   karena sebuah resource tidak boleh didefinisikan dua kali. Ia karenanya
   dibuka lewat patch, sedangkan empat pengaman lain — `deletion_protection`,
   `skip_final_snapshot`, `recovery_window_in_days`, dan `force_destroy` —
   memang atribut biasa dan dibuka variabel `izinkan_hapus`.

2. **Role dibuat sebelum dump dipulihkan.** `pg_dump` tidak membawa role:
   keduanya objek tingkat cluster, dan `edutrack_owner` bukan superuser
   sehingga tidak dapat mengekspornya. Dump memuat `GRANT` yang menunjuk
   keduanya, dan `pg_restore` berhenti dengan `role "app_ro" does not exist`
   apabila urutannya dibalik.

3. **Sidik jari dibaca dari basis data, bukan dari berkas dump.** Dua dump dari
   data yang sama tidak menghasilkan berkas yang sama — format `-Fc`
   terkompresi dan memuat stempel waktu. Membandingkan berkas dump selalu
   berkata "berubah", dan jawabannya baru diperoleh sesudah datanya terlanjur
   ditransfer.

4. **Bucket state dihapus paling akhir, dengan CLI.** Ia menyimpan state yang
   sedang dipakai perintah yang menghapusnya. `turunkan.sh` mengeluarkannya
   dari state Terraform lebih dahulu, lalu menghapusnya sendiri — termasuk
   seluruh versi dan delete marker, sebab `aws s3 rb --force` hanya membuang
   versi terkini dan bucket berversi tetap menolak dihapus.

## Cadangan

```
~/.edutrack/dump/edutrack.dump    basis data, format custom
~/.edutrack/dump/edutrack.sidik   sidik jari, tanggal, ukuran
```

Berkasnya **diganti bersih** setiap kali data berubah; tidak ada salinan lama.
Dump ditulis ke nama sementara lebih dahulu dan baru dipindahkan sesudah utuh,
sehingga dump yang gagal di tengah tidak menimpa dump yang baik.

Isinya juga dapat dipulihkan ke PostgreSQL mana pun, termasuk `docker-compose`
setempat — inilah yang membedakannya dari snapshot RDS, yang hanya dapat
menjadi instance RDS baru di akun dan region yang sama.

```bash
pg_restore --dbname=edutrack ~/.edutrack/dump/edutrack.dump
```

## Yang sengaja tidak ikut dihapus

Seluruhnya berbiaya nol, dan tanpa ketiganya tidak ada yang dapat meminjam
apa pun:

| Sumber daya | Sebab |
|---|---|
| OIDC provider GitHub | Dibaca `iam-oidc.tf` sebagai *data source* — ia dibuat dengan tangan pada B0.5 dan tidak pernah dimiliki Terraform. Memulihkannya adalah titik henti manusia ([RUNBOOK-OIDC.md](../../context/RUNBOOK-OIDC.md)) |
| User `Andreas`, grup `Edutrack-dev` | Identitas yang meminjam role |
| Role `edutrack-terraform` | Yang dipinjam |

## Sesudah membangun kembali

**Domain CloudFront berbeda setiap kali.** `naikkan.sh` memperbarui
`ALAMAT_PUBLIK` pada repositori backend lewat `gh`; apabila `gh` tidak ada, ia
mencetak nilainya dan langkah itu harus dikerjakan dengan tangan. Terlewat,
langkah 11 [§3.3](../../context/DEPLOYMENT.md) tetap lulus sambil menguji
alamat yang sudah mati.
