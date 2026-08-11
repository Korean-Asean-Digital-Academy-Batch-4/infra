# B4 — pembuktian penandatanganan OAC atas request ber-body

| Keterangan | Isi |
|---|---|
| **Tahap** | **B4** — [AGENTS.md §8.2](../../context/AGENTS.md) |
| **Diwajibkan** | [ARCHITECTURE.md §12.2](../../context/ARCHITECTURE.md), peringatan kedua |
| **Kapan** | **Hari pertama infrastruktur naik**, sementara image `:bootstrap` masih terpasang |
| **Dinilai oleh** | **Manusia.** Skrip melaporkan angka; yang menyimpulkan orang — [AGENTS.md §8.2](../../context/AGENTS.md) |

## Apa yang sesungguhnya diuji

CloudFront Origin Access Control menandatangani setiap request menuju origin dengan SigV4, dan Function URL beraut `AWS_IAM` menolak apa pun yang tanda tangannya tidak cocok. Untuk request `GET`, susunan ini sudah lama terbukti.

**Yang belum terbukti adalah request ber-body.** SigV4 memasukkan sidik jari payload ke dalam tanda tangannya. Apabila CloudFront menandatangani body lalu ada yang mengubahnya di tengah jalan — pemadatan, penyandian ulang, pemotongan — tanda tangannya tidak lagi cocok dan Lambda menolak dengan `403`. Apabila CloudFront **tidak** menandatangani body, request lolos tetapi body-nya tidak dijamin sampai utuh.

Keduanya berakibat sama bagi EduTrack: **Simpan Nilai sekelas tidak berfungsi**. Bedanya, yang pertama gagal terang-terangan dan yang kedua gagal diam-diam.

Inilah sebabnya pembuktiannya dituntut sekarang, ketika API masih berupa stub — bukan ketika frontend mulai menyimpan nilai dan penyebabnya tertutup lima lapis kode.

## Menjalankan

Menuntut image `:bootstrap` sedang terpasang, yaitu keadaan tepat sesudah `terraform apply` pada `infra/` dan sebelum rilis pertama. Alat ukurnya berada di dalam image itu — [`../bootstrap-image/`](../bootstrap-image/).

```bash
./infra/uji-oac/uji-oac.sh "$(terraform -chdir=infra output -raw domain_cloudfront)"
```

Menyertakan uji jalur langsung sekaligus:

```bash
URL_FUNGSI="$(terraform -chdir=infra output -raw url_fungsi_api)" ./infra/uji-oac/uji-oac.sh "$(terraform -chdir=infra output -raw domain_cloudfront)"
```

## Yang diperiksa

| # | Uji | Membuktikan |
|:--:|---|---|
| 1 | `GET /api/healthz` | Jalur tanpa body tembus. Diperiksa lebih dahulu supaya kegagalan berikutnya dapat dipastikan berasal dari **body**-nya |
| 2 | `POST` kecil | Body sampai utuh pada metode yang paling sering dipakai |
| 3 | `PATCH` kecil | Metode kedua yang dipakai [API.md](../../context/API.md), diuji tersendiri karena OAC memperlakukan metode secara berbeda |
| 4 | `POST` 240 nilai | Simpan Nilai sekelas — 30 siswa × 8 komponen, sekitar 29 KB ([ARCHITECTURE.md §14.1](../../context/ARCHITECTURE.md)). Batas ukuran yang menyebabkan pemotongan **tidak pernah terlihat pada body kecil** |
| 5 | `POST` langsung ke Function URL | Alamat yang bocor tidak dapat dipakai siapa pun — [ARCHITECTURE.md Pasal 2](../../context/ARCHITECTURE.md). Wajib `403` |

Yang dibandingkan **sidik jari SHA-256**, bukan panjangnya. Body yang terpotong tertangkap keduanya; body yang berubah isinya karena penyandian ulang hanya tertangkap sidik jari.

## Membaca hasilnya

| Gejala | Artinya | Yang dilakukan |
|---|---|---|
| Seluruhnya lulus | Susunan OAC menandatangani dan meneruskan body dengan benar | Catat hasilnya di [KEMAJUAN.md](../../context/KEMAJUAN.md), lanjut ke B5 |
| Uji 1 gagal | Bukan persoalan body. OAC, izin `lambda:InvokeFunctionUrl`, atau perilaku `/api/*` yang belum benar | Perbaiki itu dahulu; sisa uji tidak bermakna |
| `403` hanya pada uji ber-body | Tanda tangan mencakup body, dan body berubah di tengah jalan | Periksa origin request policy — wajib `AllViewerExceptHostHeader`. Pastikan tidak ada CloudFront Function maupun Lambda@Edge yang menyentuh body |
| `200` tetapi sidik jari berbeda | Body sampai dalam keadaan berubah, dan **tidak ada yang menolaknya** | Bandingkan `panjang_diterima` dengan `panjang_header`. Selisih menunjuk pemotongan; sama panjang tetapi berbeda sidik jari menunjuk penyandian ulang |
| Uji 5 tidak `403` | Function URL dapat dipanggil siapa pun yang mengetahui alamatnya | **Hentikan seluruh penaikan.** Periksa `authorization_type` dan `aws_lambda_permission.cloudfront` |

Bidang `x_amz_content_sha256` pada jawaban menunjukkan payload apa yang dinyatakan CloudFront ikut ditandatangani. Nilai `UNSIGNED-PAYLOAD` berarti body **tidak** ikut ditandatangani — sah menurut SigV4, dan artinya keutuhan body bersandar sepenuhnya pada TLS antara CloudFront dan Lambda. Itu bukan kegagalan, tetapi wajib diketahui alih-alih diasumsikan.

## Sesudah lulus

Hasilnya dicatat pada [KEMAJUAN.md](../../context/KEMAJUAN.md) sebagai bukti B4. Apabila ada yang mengejutkan — terutama nilai `x_amz_content_sha256` — temuannya ditulis ke [ARCHITECTURE.md §12.2](../../context/ARCHITECTURE.md), karena di sanalah peringatan ini bermula dan di sanalah orang berikutnya akan mencarinya.

Skrip ini **tidak dihapus sesudah B4 selesai**. Ia dijalankan kembali setiap kali susunan CloudFront berubah — kebijakan cache, perilaku baru, atau CloudFront Function yang ditambahkan kemudian. Jalur `/uji-body` sendiri lenyap bersama image `:bootstrap`, sehingga pemakaian ulangnya menuntut image itu dipasang sementara.
