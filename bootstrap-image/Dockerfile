# Image `:bootstrap` — DEPLOYMENT.md sec 2.3.
#
# TERPISAH dari image aplikasi, dan itu bukan kerapian melainkan keharusan.
# Aplikasi mewajibkan DATABASE_URL, DATABASE_URL_RO, dan kunci AI ada saat
# menyala (backend/src/config.ts). Dengan image aplikasi, container fungsi mati
# sebelum sempat mendengarkan, readiness check /healthz tidak pernah lulus, dan
# `terraform apply` pada infra/ gagal justru pada langkah yang seharusnya
# membuktikan infrastrukturnya sehat.
#
# Tanpa dependensi: tidak ada package.json, tidak ada npm install, tidak ada
# lockfile yang perlu dijaga tetap selaras dengan apa pun.

FROM node:24-slim

# Versi adapter WAJIB dipatok — CK-13. Sama persis dengan backend/Dockerfile:
# yang diuji di sini adalah jalurnya, sehingga menguji versi lain tidak
# membuktikan apa-apa tentang yang akan berjalan.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 /lambda-adapter /opt/extensions/lambda-adapter

WORKDIR /app
COPY server.mjs ./

ENV PORT=8080
ENV AWS_LWA_READINESS_CHECK_PATH=/healthz
EXPOSE 8080
CMD ["node", "server.mjs"]
