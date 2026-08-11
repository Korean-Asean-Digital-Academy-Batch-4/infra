# Image `:bootstrap`

| Keterangan | Isi |
|---|---|
| **Tahap** | **B2** — [AGENTS.md §8.2](../../context/AGENTS.md) |
| **Kedudukan** | Catatan pemakaian. Ketentuannya pada [DEPLOYMENT.md §2.3](../../context/DEPLOYMENT.md) |
| **Dijalankan oleh** | **Manusia.** Pendorongan ke ECR menuntut kredensial AWS — [AGENTS.md §10](../../context/AGENTS.md) |

Aplikasi paling kecil yang cukup untuk membuat kedua fungsi Lambda. Fungsi Lambda tidak dapat dibuat tanpa image, sedangkan image aplikasi belum dapat dipakai — jadi yang didorong lebih dahulu adalah ini.

## Kenapa bukan image aplikasi

`backend/src/config.ts` mewajibkan `DATABASE_URL`, `DATABASE_URL_RO`, dan kunci API AI sudah ada pada saat proses menyala. Pada `terraform apply` pertama, RDS memang sudah ada tetapi **kedua rahasia `app_rw` dan `app_ro` belum diisi** — pengisiannya baru dapat dilakukan sesudah instance-nya hidup ([DEPLOYMENT.md §5.1](../../context/DEPLOYMENT.md)).

Akibatnya berantai: container mati sebelum sempat mendengarkan, readiness check `GET /healthz` tidak pernah lulus, dan `terraform apply` gagal pada langkah yang justru dipasang untuk membuktikan infrastrukturnya sehat.

Image ini karenanya **tanpa dependensi dan tanpa satu pun variabel lingkungan yang wajib**.

## Yang disajikannya

| Jalur | Jawaban |
|---|---|
| `GET /healthz` dan `GET /api/healthz` | `200` — readiness check Lambda Web Adapter |
| `POST` dan `PATCH` pada `/uji-body` maupun `/api/uji-body` | `200` beserta panjang dan `sha256` body yang **benar-benar diterima** |
| selainnya | `404` |

**Dua alamat bagi masing-masing, dan keduanya diperlukan.** Bentuk tanpa awalan dipanggil adapter dari dalam container; bentuk ber-awalan `/api` dipanggil dari luar lewat CloudFront, yang hanya meneruskan `/api/*` ke Lambda ([ARCHITECTURE.md Pasal 3](../../context/ARCHITECTURE.md)). Aplikasi yang sesungguhnya memakai bentuk yang sama.

Jalur kedua adalah alat ukur **B4**, yaitu pembuktian penandatanganan OAC atas request ber-body yang diwajibkan [ARCHITECTURE.md §12.2](../../context/ARCHITECTURE.md) pada hari pertama infrastruktur naik. Prosedurnya pada [`../uji-oac/README.md`](../uji-oac/README.md).

## Membangun dan mendorong

Arsitekturnya **wajib arm64** — fungsi Lambda disetel `arm64` ([ARCHITECTURE.md Pasal 6](../../context/ARCHITECTURE.md)). Membangun di mesin x86 tanpa `--platform` menghasilkan image yang lolos push tetapi gagal saat fungsi dibuat.

```bash
eval "$(aws configure export-credentials --profile edutrack --format env)"
```

```bash
aws ecr get-login-password --region ap-southeast-3 | docker login --username AWS --password-stdin 274286556151.dkr.ecr.ap-southeast-3.amazonaws.com
```

```bash
docker buildx build --platform linux/arm64 --provenance=false -t 274286556151.dkr.ecr.ap-southeast-3.amazonaws.com/edutrack:bootstrap --push infra/bootstrap-image
```

`--provenance=false` mencegah buildx menerbitkan manifest list beserta lampiran attestation. Lambda menolak image yang berupa manifest list, dan pesannya tidak menyebutkan attestation sama sekali.

Verifikasi tanpa menarik image-nya:

```bash
aws ecr describe-images --repository-name edutrack --image-ids imageTag=bootstrap --region ap-southeast-3 --query 'imageDetails[0].{Dorong:imagePushedAt,Ukuran:imageSizeInBytes,Digest:imageDigest}'
```

## Sesudah ini

Tag `:bootstrap` **tidak pernah diperbarui lagi**. Sejak `terraform apply` pada `infra/` selesai, isi fungsi dimiliki CI ([CK-D-02](../../context/DEPLOYMENT.md)), dan tag yang dipakai adalah git SHA.

Tag ini tetap tidak boleh dihapus: aturan daur hidup ECR sengaja tidak menghapus image bertag ([DEPLOYMENT.md §2.5](../../context/DEPLOYMENT.md)), karena `terraform apply` yang membuat ulang fungsi akan mencarinya kembali.

## Mencobanya setempat lebih dahulu

Tidak menuntut AWS sama sekali:

```bash
docker build -t edutrack-bootstrap infra/bootstrap-image && docker run --rm -p 8080:8080 edutrack-bootstrap
```

```bash
curl -sS localhost:8080/healthz && printf '\n' && curl -sS -X POST localhost:8080/uji-body -H 'content-type: application/json' -d '{"nilai":88}'
```
