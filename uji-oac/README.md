# B4 — pembuktian penandatanganan OAC atas request ber-body

| Keterangan | Isi |
|---|---|
| **Tahap** | **B4** — [AGENTS.md §8.2](../../context/AGENTS.md) |
| **Diwajibkan** | [ARCHITECTURE.md §12.2](../../context/ARCHITECTURE.md), peringatan kedua |
| **Kapan** | **Hari pertama infrastruktur naik**, sementara image `:bootstrap` masih terpasang |
| **Dinilai oleh** | **Manusia.** Skrip melaporkan angka; yang menyimpulkan orang — [AGENTS.md §8.2](../../context/AGENTS.md) |
| **Keadaan** | ✅ **Selesai 12 Agustus 2026 — 5 lulus, 0 gagal.** Hasilnya menjadi **CK-A-12** pada [ARCHITECTURE.md](../../context/ARCHITECTURE.md) |

> ## Jawabannya: ya, dan ada syaratnya
>
> Request ber-body **wajib** membawa header `x-amz-content-sha256` berisi SHA-256 heksadesimal dari body. Tanpanya `POST` dan `PATCH` dijawab **403**, sementara seluruh jalur `GET` tetap sehat — sehingga kegagalannya hanya menyentuh jalur tulis.
>
> Skrip ini kini menguji **kedua sisi** kontrak itu: tanpa header wajib ditolak, dengan header wajib lolos beserta sidik jari yang cocok. Ketentuan lengkapnya pada CK-A-12; dua jebakan penaikannya pada [DEPLOYMENT §5.2](../../context/DEPLOYMENT.md).

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
| Uji 1 gagal — `GET` pun `403` | Bukan persoalan body sama sekali. **Dugaan pertama: izin `lambda:InvokeFunction` hilang** — OAC menuntut dua izin, bukan satu ([DEPLOYMENT §5.2](../../context/DEPLOYMENT.md)) | Perbaiki itu dahulu; sisa uji tidak bermakna |
| `GET` lolos, `403` hanya pada uji ber-body **dengan header** | Sidik jari yang dikirim tidak cocok dengan body yang sampai | Periksa origin request policy — wajib `AllViewerExceptHostHeader`. Pastikan tidak ada CloudFront Function maupun Lambda@Edge yang menyentuh body |
| Uji ber-body **tanpa header** ternyata lolos | Perilaku layanan AWS berubah — Lambda kini menerima payload tak bertanda tangan | Bukan kegagalan susunan. **CK-A-12 perlu ditinjau ulang**, beserta pembungkus `fetch` di frontend |
| `200` tetapi sidik jari berbeda | Body sampai dalam keadaan berubah, dan **tidak ada yang menolaknya** | Bandingkan `panjang_diterima` dengan `panjang_header`. Selisih menunjuk pemotongan; sama panjang tetapi berbeda sidik jari menunjuk penyandian ulang |
| Uji terakhir tidak `403` | Function URL dapat dipanggil siapa pun yang mengetahui alamatnya | **Hentikan seluruh penaikan.** Periksa `authorization_type` dan `aws_lambda_permission.cloudfront` |

**Membedakan dua bentuk `403` dalam hitungan detik.** Badan jawabannya berbeda, dan perbedaannya menentukan ke mana harus mencari:

| Badan jawaban | Artinya |
|---|---|
| `{"Message":"Forbidden"}` | Tidak ada tanda tangan sama sekali — OAC tidak menandatangani, atau requestnya memang langsung |
| `{"Message":"Forbidden. For troubleshooting …"}` | Tanda tangan **ada** dan ditolak — persoalannya izin atau sidik jari payload |

Bidang `x_amz_content_sha256` pada jawaban menunjukkan payload apa yang dinyatakan CloudFront ikut ditandatangani. Nilai `UNSIGNED-PAYLOAD` berarti body **tidak** ikut ditandatangani — sah menurut SigV4, dan artinya keutuhan body bersandar sepenuhnya pada TLS antara CloudFront dan Lambda. Itu bukan kegagalan, tetapi wajib diketahui alih-alih diasumsikan.

## Sesudah lulus

Hasilnya dicatat pada [KEMAJUAN.md](../../context/KEMAJUAN.md) sebagai bukti B4. Apabila ada yang mengejutkan — terutama nilai `x_amz_content_sha256` — temuannya ditulis ke [ARCHITECTURE.md §12.2](../../context/ARCHITECTURE.md), karena di sanalah peringatan ini bermula dan di sanalah orang berikutnya akan mencarinya.

Skrip ini **tidak dihapus sesudah B4 selesai**. Ia dijalankan kembali setiap kali susunan CloudFront berubah — kebijakan cache, perilaku baru, atau CloudFront Function yang ditambahkan kemudian. Jalur `/uji-body` sendiri lenyap bersama image `:bootstrap`, sehingga pemakaian ulangnya menuntut image itu dipasang sementara.
