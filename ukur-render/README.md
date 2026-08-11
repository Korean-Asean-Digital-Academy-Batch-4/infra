# B7 — pengukuran render tiga puluh PDF di Lambda

| Keterangan | Isi |
|---|---|
| **Tahap** | **B7** — [AGENTS.md §8.2](../../context/AGENTS.md) |
| **Diwajibkan** | [API.md §13.3](../../context/API.md) |
| **Menutup** | Gerbang **A7** yang tersisa — [KEMAJUAN.md](../../context/KEMAJUAN.md) |
| **Dinilai oleh** | **Manusia.** Skrip melaporkan angka; keputusannya orang |

## Angka yang dicari

[API.md §13.3](../../context/API.md) menyebut satu angka yang belum pernah diukur siapa pun:

> lama render tiga puluh PDF pdfmake berurutan **beserta unggahannya ke S3**, di dalam fungsi Lambda 1024 MB arm64

Yang dibandingkan angka itu adalah **anggaran lunak 20 detik** pada [ARCHITECTURE.md Pasal 11](../../context/ARCHITECTURE.md).

**Pembanding lokal: 431 ms** — `npm run ukur:render` pada mesin pengembang, 30 rapor × 10 mata pelajaran, penyimpanan disk lokal menggantikan S3. Angka itu menjawab "apakah perenderannya sendiri masuk akal", **bukan** "apakah anggarannya terpenuhi di produksi". Tiga hal membedakannya dan seluruhnya menaikkan angka: CPU Lambda pada 1024 MB lebih kecil daripada mesin pengembang, S3 menggantikan disk, dan request pertama membayar cold start di dalam VPC.

## Kenapa tidak ada skrip pengukur tersendiri

Karena sudah ada jalur yang mengukur hal yang persis sama, dan ia jalur yang sesungguhnya: **finalisasi sekelas**. Satu transaksi menulis `rapor_mapel`, dan sesudah `COMMIT` seluruh berkas rapor kelas dirender lalu diunggah ke S3 di dalam request yang sama ([ARCHITECTURE.md Pasal 11](../../context/ARCHITECTURE.md)).

Menambahkan jalur pengukur tersendiri berarti mengukur kode yang bukan kode produksi, di dalam fungsi yang harus dijaga tidak memiliki jalur tambahan apa pun. Yang diukur di sini adalah tindakan yang benar-benar akan dilakukan Wali Kelas.

## Prasyarat

| # | Yang harus ada | Dari |
|:--:|---|---|
| 1 | Rilis pertama sudah berjalan — image aplikasi, bukan `:bootstrap` | **B6** |
| 2 | Satu periode aktif, satu kelas berisi **30 siswa**, dan mata pelajaran beserta komponennya | Unggah XLSX, [API.md §5.7](../../context/API.md) |
| 3 | Seluruh nilai dan presensi **lengkap** bagi setiap mata pelajaran | Tanpa ini finalisasi ditolak I-20, dan yang terukur adalah penolakannya |
| 4 | Sesi Wali Kelas kelas tersebut | `POST /api/auth/masuk` |

Prasyarat 3 adalah yang paling mudah diremehkan. Finalisasi memeriksa kelengkapan seluruh mata pelajaran lebih dahulu (AC-07); kelas yang belum lengkap dijawab `409` dalam puluhan milidetik, dan angka itu tidak mengukur apa pun.

## Menjalankan

```bash
./infra/ukur-render/ukur-render.sh
```

Skrip menuntut tiga hal dari lingkungan:

```bash
export ALAMAT="$(terraform -chdir=infra output -raw domain_cloudfront)"
export KUKI="edutrack_sesi=<token sesi Wali Kelas>"
export KELAS_REF="<uuid kelas berisi 30 siswa>"
```

Kredensial AWS untuk membaca CloudWatch diperoleh seperti biasa — role baca saja sudah cukup:

```bash
eval "$(aws configure export-credentials --profile edutrack-ro --format env)"
```

## Yang dilaporkan

| Angka | Sumber | Artinya |
|---|---|---|
| Lama request dari sisi klien | `curl` | Termasuk CloudFront dan jaringan. Yang dirasakan Wali Kelas |
| `Duration` | CloudWatch Logs, laporan invocation | Lama fungsi bekerja. **Inilah angka §13.3** |
| `Init Duration` | idem | Cold start. Muncul hanya pada invocation pertama |
| `Max Memory Used` | idem | Terhadap 1024 MB. Menjawab apakah memorinya yang membatasi |
| `berkas_terender` | jawaban endpoint | **Yang paling menentukan.** Berapa dari 30 berkas selesai di dalam anggaran |

## Membaca hasilnya

| Keadaan | Artinya | Yang dilakukan |
|---|---|---|
| `berkas_terender` = 30, `Duration` jauh di bawah 20 detik | CK-API-12 bertahan dengan margin | Catat angkanya, tutup gerbang A7 |
| `berkas_terender` = 30, `Duration` mendekati 20 detik | Bertahan, tetapi tanpa margin | Catat, dan catat pula bahwa kelas lebih besar akan melampauinya |
| `berkas_terender` < 30 | Anggaran lunak bekerja **sebagaimana dirancang** | Bukan kegagalan — [API.md §13.3](../../context/API.md) menyatakan yang berubah hanya jumlah berkas yang sempat dirender, dan jalur render-saat-unduh menutupinya |
| `Duration` mendekati 30 detik | Batas waktu **keras** fungsi yang terancam, bukan anggaran lunaknya | Ini yang sesungguhnya berbahaya. Periksa apakah anggaran lunak benar-benar menghentikan render |
| `Max Memory Used` mendekati 1024 MB | Memori yang membatasi, bukan CPU | Menaikkan memori menaikkan porsi CPU sekaligus — satu variabel Terraform |

**Ukur sekurang-kurangnya tiga kali**, dan buang yang pertama. Invocation pertama membayar cold start beserta pembacaan rahasia dari Secrets Manager, dan angka itu tidak berulang pada finalisasi kelas berikutnya.

Finalisasi **tidak dapat diulang pada kelas yang sama**: status rapor tidak dapat mundur (I-21), dan tidak ada jalur buka kembali. Pengukuran berulang karenanya menuntut kelas yang berbeda-beda, masing-masing berisi 30 siswa dengan nilai lengkap.

## Sesudah diukur

1. Angkanya dicatat pada [KEMAJUAN.md](../../context/KEMAJUAN.md), menggantikan baris yang menyatakan pengukuran Lambda masih menunggu.
2. [API.md §13.3](../../context/API.md) disunting langsung — ia isi deskriptif, dan kalimat "belum pernah diukur siapa pun" tidak lagi benar.
3. Utang teknis "pengukuran lama render tiga puluh PDF **di Lambda**" pada [KEMAJUAN.md](../../context/KEMAJUAN.md) §5 ditutup.
4. Apabila angkanya menggugurkan salah satu alasan **CK-API-12**, yang ditulis adalah Catatan Keputusan **baru** yang mengamandemennya — entri lama tidak pernah disunting ([AGENTS.md §1.2](../../context/AGENTS.md)).
