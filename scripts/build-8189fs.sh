#!/bin/bash
# build-8189fs.sh - compila o driver RTL8189FS/FTV (branch rtl8189fs de jwrdegoede) com o patch do
# projeto contra os headers de um kernel do ophub, em um host x86_64 (GitHub Actions ou WSL).
#
# Uso: bash scripts/build-8189fs.sh <versao_ophub> [dir_saida]
#   ex.: bash scripts/build-8189fs.sh 6.12.109 out/
# Produz: <dir_saida>/8189fs-<versao>-ophub.ko
#
# Variaveis opcionais:
#   DRIVER_REPO  (padrao https://github.com/jwrdegoede/rtl8189ES_linux.git)
#   DRIVER_REF   (padrao 13bbdbc, branch rtl8189fs de 11/09/2026)
#   DRIVER_PATCH (padrao drivers/rtl8189fs/8189fs-sdio-chunk-fifo-transfers.patch)
#   CROSS_CC     (padrao aarch64-linux-gnu-gcc-14; o kernel do ophub usa -fmin-function-alignment, gcc >= 14)
set -euo pipefail

KVER="${1:?versao do kernel ophub, ex. 6.12.109}"
OUT="${2:-out}"
DRIVER_REPO="${DRIVER_REPO:-https://github.com/jwrdegoede/rtl8189ES_linux.git}"
DRIVER_REF="${DRIVER_REF:-13bbdbc}"
DRIVER_PATCH="${DRIVER_PATCH:-$(cd "$(dirname "$0")/.." && pwd)/drivers/rtl8189fs/8189fs-sdio-chunk-fifo-transfers.patch}"
CROSS_CC="${CROSS_CC:-aarch64-linux-gnu-gcc-14}"
KREL="${KVER}-ophub"
WORK="$(pwd)/build-8189fs"
JOBS="$(nproc)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

for t in curl tar gcc "$CROSS_CC" aarch64-linux-gnu-ld make git modinfo file python3; do
    command -v "$t" >/dev/null || { echo "ferramenta ausente: $t"; exit 1; }
done
[[ -f "$DRIVER_PATCH" ]] || { echo "patch nao encontrado: $DRIVER_PATCH"; exit 1; }

mkdir -p "$WORK"
cd "$WORK"

echo "[1/5] kernel ophub $KVER (headers)"
if [[ ! -f "$KVER.tar.gz" ]]; then
    curl -fL -o "$KVER.tar.gz" "https://github.com/ophub/kernel/releases/download/kernel_stable/$KVER.tar.gz" \
        || { echo "kernel $KVER nao esta mais em kernel_stable (o ophub mantem so as 4 ultimas de cada serie)"; exit 1; }
fi
rm -rf "$KVER" hdr && mkdir hdr
tar -xzf "$KVER.tar.gz"
tar -xzf "$KVER/header-$KREL.tar.gz" -C hdr
tar -xzf "$KVER/boot-$KREL.tar.gz" -C "$WORK" "config-$KREL"
cp "config-$KREL" hdr/.config
grep -q "UTS_RELEASE \"$KREL\"" hdr/include/generated/utsrelease.h || { echo "utsrelease nao bate com $KREL"; exit 1; }

echo "[2/5] adaptando os headers para host x86_64"
cd hdr
# o auto.conf.cmd grava a toolchain usada e forca 'syncconfig' (que precisa dos Kconfig, ausentes) se ela mudar
printf 'deps_config :=\n' > include/config/auto.conf.cmd
touch include/config/auto.conf include/generated/autoconf.h include/generated/rustc_cfg
# as ferramentas de host vem compiladas para aarch64; recompilar as duas que o build de modulo usa
find scripts -type f -perm -u+x -exec file {} + | grep "ARM aarch64" | cut -d: -f1 | xargs -r rm -f
find scripts -name "*.o" -delete
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc scripts_basic
gcc -O2 -I scripts/include -I scripts/mod -o scripts/mod/modpost \
    scripts/mod/modpost.c scripts/mod/file2alias.c scripts/mod/sumversion.c scripts/mod/symsearch.c
file scripts/basic/fixdep scripts/mod/modpost | grep -q "x86-64" || { echo "host tools nao recompiladas"; exit 1; }
cd "$WORK"

echo "[3/5] fonte do driver ($DRIVER_REPO @ $DRIVER_REF)"
rm -rf drv
git clone -q "$DRIVER_REPO" drv
cd drv
git checkout -q "$DRIVER_REF"
if grep -q "rtw_sdio_port_chunk_size" hal/rtl8188f/sdio/sdio_ops.c; then
    echo "      correcao ja presente no upstream, patch nao aplicado"
else
    git apply --check "$DRIVER_PATCH"
    git apply "$DRIVER_PATCH"
    echo "      patch aplicado"
fi

echo "[4/5] compilando"
make -j"$JOBS" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="$CROSS_CC" KSRC="$WORK/hdr" modules > "$WORK/build.log" 2>&1 \
    || { tail -30 "$WORK/build.log"; exit 1; }

echo "[5/5] verificando"
VM="$(modinfo 8189fs.ko | awk '/^vermagic/{print $2}')"
[[ "$VM" == "$KREL" ]] || { echo "vermagic '$VM' != '$KREL'"; exit 1; }
modinfo 8189fs.ko | grep -q "sdio:c\*v024CdF179" || { echo "alias SDIO 024c:f179 ausente"; exit 1; }
cp 8189fs.ko "$OUT/8189fs-$KREL.ko"
sha256sum "$OUT/8189fs-$KREL.ko"
echo "pronto: $OUT/8189fs-$KREL.ko (vermagic $(modinfo "$OUT/8189fs-$KREL.ko" | awk '/^vermagic/{print $2}'))"
