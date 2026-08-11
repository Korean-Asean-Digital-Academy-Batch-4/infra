import { createHash } from "node:crypto";
import { createServer } from "node:http";

/**
 * Aplikasi minimal untuk image `:bootstrap` — DEPLOYMENT.md §2.3.
 *
 * Tanpa dependensi, tanpa basis data, dan tanpa satu pun variabel lingkungan
 * yang wajib. Ia hanya perlu hidup cukup lama untuk membuktikan bahwa VPC,
 * Function URL, CloudFront, dan alias Lambda sudah tersusun benar — sesudah itu
 * CI menggantinya dengan image aplikasi yang sesungguhnya.
 */

const PORT = Number(process.env.PORT ?? 8080);

const server = createServer((req, res) => {
  const jalur = (req.url ?? "/").split("?")[0];

  // Readiness check Lambda Web Adapter — ARCHITECTURE.md Pasal 6. Trafik tidak
  // masuk sebelum jalur ini menjawab 200.
  //
  // Dua alamat, sama seperti aplikasi yang sesungguhnya: `/healthz` dipanggil
  // adapter dari dalam container, `/api/healthz` dipanggil dari luar lewat
  // CloudFront — dan hanya `/api/*` yang diteruskan ke Lambda.
  if (req.method === "GET" && (jalur === "/healthz" || jalur === "/api/healthz")) {
    jawab(res, 200, { data: { proses: "siap", image: "bootstrap" } });
    return;
  }

  // Alat ukur B4 — ARCHITECTURE.md §12.2 peringatan kedua.
  //
  // Origin Access Control menandatangani request menuju Function URL dengan
  // SigV4. Yang belum terbukti adalah perlakuannya terhadap request BER-BODY:
  // apakah body sampai utuh, dan apakah tanda tangannya mencakup body itu.
  // Jalur ini menjawabnya dengan mengembalikan panjang dan sidik jari body yang
  // benar-benar diterima, sehingga pengirim dapat membandingkannya dengan yang
  // dikirim. Dibuat sekarang, ketika API masih berupa stub — bukan ditemukan
  // ketika frontend mulai menyimpan nilai.
  if (
    (req.method === "POST" || req.method === "PATCH") &&
    (jalur === "/uji-body" || jalur === "/api/uji-body")
  ) {
    const potongan = [];
    req.on("data", (bagian) => potongan.push(bagian));
    req.on("end", () => {
      const isi = Buffer.concat(potongan);
      jawab(res, 200, {
        data: {
          metode: req.method,
          panjang_diterima: isi.length,
          panjang_header: req.headers["content-length"] ?? null,
          sha256: createHash("sha256").update(isi).digest("hex"),
          // Nama header yang dipakai CloudFront untuk menyatakan payload apa
          // yang ikut ditandatangani. Kosong berarti body TIDAK ditandatangani.
          x_amz_content_sha256: req.headers["x-amz-content-sha256"] ?? null,
        },
      });
    });
    req.on("error", () => jawab(res, 400, kesalahan("BODY_GAGAL_DIBACA", "Body tidak terbaca.")));
    return;
  }

  jawab(
    res,
    404,
    kesalahan("TIDAK_DITEMUKAN", "Image bootstrap hanya melayani /healthz dan /uji-body."),
  );
});

function jawab(res, status, isi) {
  const badan = JSON.stringify(isi);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(badan),
  });
  res.end(badan);
}

function kesalahan(kode, pesan) {
  return { kesalahan: { kode, pesan } };
}

server.listen(PORT, () => {
  console.log(`edutrack bootstrap mendengarkan di port ${PORT}`);
});

for (const sinyal of ["SIGTERM", "SIGINT"]) {
  process.on(sinyal, () => server.close());
}
