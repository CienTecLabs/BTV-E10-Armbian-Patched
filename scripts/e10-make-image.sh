#!/bin/bash
# e10-make-image.sh - gera a imagem Armbian (ophub) pronta para a BTV Express E10 (Amlogic S905X2)
#
# Parte da imagem oficial do ophub para s905x2 (serie 6.12) e injeta:
#   1. /boot/dtb/amlogic/meson-g12a-btv-e10.dtb  (gerado a partir do meson-g12a-sei510.dtb da propria imagem)
#   2. FDT=/dtb/amlogic/meson-g12a-btv-e10.dtb em /boot/uEnv.txt
#   3. /lib/modules/<kver>/kernel/drivers/net/wireless/realtek/8189fs.ko (driver com o patch E10) + depmod
#   4. /etc/modprobe.d/8189fs.conf
#   5. entrada "BTV-Express-E10" (ID 309) em /etc/model_database.conf, para o armbian-install / armbian-update
#   6. LEDs frontais: no pwm-leds no DTB (POWER = PWM_AO_A/GPIOAO_11, NET = PWM_AO_C/GPIOAO_4, brilho 0..255,
#      uso padrao so 0 ou 255) + dispatcher do NetworkManager para o NET
#   7. /etc/e10-release com o registro do que foi feito
#
# Uso (Ubuntu/WSL x86_64, como root):
#   sudo bash e10-make-image.sh <imagem_base.img.gz> <dir_do_pacote> [imagem_saida.img.gz]
# O pacote precisa conter: 8189fs-<kver>.ko (kver = versao do kernel da imagem, ex. 6.12.109-ophub) e 8189fs.conf
# Requisitos: losetup, mount, dtc (device-tree-compiler), depmod (kmod), mtools, python3, gzip, sha256sum
set -euo pipefail

BASE="${1:?imagem base .img.gz}"
PKG="${2:?diretorio do pacote}"
OUT="${3:-}"

[[ "$(id -u)" == "0" ]] || { echo "rode como root (sudo)"; exit 1; }
for t in losetup mount dtc depmod python3 gzip sha256sum mcopy; do
    command -v "$t" >/dev/null || { echo "ferramenta ausente: $t"; exit 1; }
done
[[ -f "$BASE" ]] || { echo "imagem base nao encontrada: $BASE"; exit 1; }
[[ -f "$PKG/8189fs.conf" ]] || { echo "falta $PKG/8189fs.conf"; exit 1; }

WORK="$(pwd)/e10-work"
mkdir -p "$WORK/root"
IMG="$WORK/e10.img"
LOOP=""

cleanup() {
    set +e
    sync
    mountpoint -q "$WORK/root" && umount "$WORK/root"
    [[ -n "$LOOP" ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

echo "[1/7] descompactando $BASE"
rm -f "$IMG"
gunzip -c "$BASE" > "$IMG"

echo "[2/7] montando"
# um loop por particao, por offset (funciona sem partscan/udev, inclusive no WSL)
part_geom() {   # imprime "inicio_setor tamanho_setores" da particao $1 lendo a tabela MBR (sem depender de sfdisk)
    python3 - "$IMG" "$1" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(0x1BE + 16 * (int(sys.argv[2]) - 1)); e = f.read(16)
start, size = struct.unpack('<II', e[8:16])
print(start, size)
PY
}
read -r P1S P1N <<< "$(part_geom 1)"
read -r P2S P2N <<< "$(part_geom 2)"
[[ -n "$P1S" && -n "$P2S" ]] || { echo "nao consegui ler a tabela de particoes de $IMG"; exit 1; }
LOOP="$(losetup -f --show -o $((P2S*512)) --sizelimit $((P2N*512)) "$IMG")"
mount "$LOOP" "$WORK/root"
# particao de boot (FAT32) manipulada com mtools direto no arquivo, sem montar (independe de suporte vfat no host)
export MTOOLS_SKIP_CHECK=1
BOOTFS="$IMG@@$((P1S*512))"
mdir -i "$BOOTFS" ::/ >/dev/null || { echo "particao de boot FAT nao legivel"; exit 1; }

KVER="$(ls "$WORK/root/lib/modules" | grep -E '^[0-9]' | head -1)"
[[ -n "$KVER" ]] || { echo "nenhum kernel em /lib/modules da imagem"; exit 1; }
MOD="$PKG/8189fs-${KVER}.ko"
[[ -f "$MOD" ]] || { echo "kernel da imagem e $KVER; nao ha $MOD no pacote"; exit 1; }
BASEDTB="$WORK/sei510.dtb"
mcopy -o -i "$BOOTFS" ::/dtb/amlogic/meson-g12a-sei510.dtb "$BASEDTB" || { echo "sem meson-g12a-sei510.dtb na imagem"; exit 1; }
echo "      kernel da imagem: $KVER"

echo "[3/7] gerando meson-g12a-btv-e10.dtb a partir do sei510 da imagem"
dtc -q -I dtb -O dts -o "$WORK/sei510.dts" "$BASEDTB"
python3 - "$WORK/sei510.dts" "$WORK/e10.dts" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
# 1. identificacao
old = '\tmodel = "SEI Robotics SEI510";'
assert src.count(old) == 1, "model do sei510 nao encontrado"
src = src.replace(old, '\tmodel = "BTV Express E10 (S905X2, base SEI510, SDIO 25 MHz default-speed)";')
# 2. pull-up interno nos pinos SDIO (como o kernel vendor da Amlogic)
old = 'groups = "sdio_d0\\0sdio_d1\\0sdio_d2\\0sdio_d3\\0sdio_clk\\0sdio_cmd";\n\t\t\t\t\t\t\tfunction = "sdio";\n\t\t\t\t\t\t\tbias-disable;'
assert src.count(old) == 1, "grupo pinctrl sdio nao encontrado"
src = src.replace(old, old.replace('bias-disable;', 'bias-pull-up;'))
# 3. controlador SDIO (sd_emmc_a): sem UHS, sem high-speed, 25 MHz
s = src.index('\t\tmmc@ffe03000 {'); e = src.index('\t\tmmc@ffe05000 {')
node = src[s:e]
for p in ('\t\t\tsd-uhs-sdr50;\n', '\t\t\tcap-sd-highspeed;\n', 'max-frequency = <0x5f5e100>;'):
    assert node.count(p) == 1, "propriedade nao encontrada no mmc@ffe03000: " + p.strip()
node = node.replace('\t\t\tsd-uhs-sdr50;\n', '').replace('\t\t\tcap-sd-highspeed;\n', '')
node = node.replace('max-frequency = <0x5f5e100>;', 'max-frequency = <25000000>;')
src = src[:s] + node + src[e:]
# 4. LEDs frontais por PWM: POWER = PWM_AO_A em GPIOAO_11 (pwm_AO_ab canal 0), NET = PWM_AO_C em GPIOAO_4
#    (pwm_AO_cd canal 0; o canal D continua no regulador VDDCPU). Nivel alto acende o verde, baixo o vermelho:
#    cada indicador e um par vermelho/verde no mesmo pino, por isso o padrao de uso e so 0 ou 255.
import re
def node_phandle(name):
    i = src.index(name); blk = src[i:src.index('\n\t\t\t\t};', i) if name.startswith('\t\t\t\tpwm-ao') else src.index('\t\t\t};', i)]
    m = re.search(r'phandle = <(0x[0-9a-f]+)>;', blk)
    assert m, "sem phandle em " + name.strip()
    return m.group(1)
ph_ab   = node_phandle('\t\t\tpwm@7000 {')       # pwm_AO_ab
ph_cd   = node_phandle('\t\t\tpwm@2000 {')       # pwm_AO_cd
ph_pa   = node_phandle('\t\t\t\tpwm-ao-a {')     # pinmux PWM_AO_A -> GPIOAO_11
ph_pc4  = node_phandle('\t\t\t\tpwm-ao-c-4 {')   # pinmux PWM_AO_C -> GPIOAO_4
# 4a. ligar pwm_AO_ab com o pinmux do PWM_AO_A
i = src.index('\t\t\tpwm@7000 {'); j = src.index('\t\t\t};', i); node = src[i:j]
assert node.count('status = "disabled";') == 1 and 'pinctrl' not in node, "pwm@7000 fora do esperado"
node = node.replace('status = "disabled";', 'status = "okay";\n\t\t\t\tpinctrl-0 = <%s>;\n\t\t\t\tpinctrl-names = "default";' % ph_pa)
src = src[:i] + node + src[j:]
# 4b. acrescentar o pinmux do PWM_AO_C ao pwm_AO_cd (que ja esta ligado para o VDDCPU)
i = src.index('\t\t\tpwm@2000 {'); j = src.index('\t\t\t};', i); node = src[i:j]
m = re.search(r'pinctrl-0 = <([^>]*)>;', node)
assert m and ph_pc4 not in m.group(1), "pwm@2000 fora do esperado"
node = node.replace(m.group(0), 'pinctrl-0 = <%s %s>;' % (m.group(1), ph_pc4))
src = src[:i] + node + src[j:]
# 4c. no pwm-leds (periodo 100000 ns = 10 kHz; brightness 0..255 em /sys/class/leds/e10:*)
anchor = '\tsdio-pwrseq {'
assert src.count(anchor) == 1, "no sdio-pwrseq nao encontrado"
leds = ('\tleds {\n\t\tcompatible = "pwm-leds";\n\n'
        '\t\tled-power {\n\t\t\tlabel = "e10:power";\n\t\t\tpwms = <%s 0x00 0x186a0 0x00>;\n\t\t\tmax-brightness = <0xff>;\n\t\t\tdefault-state = "on";\n\t\t};\n\n'
        '\t\tled-net {\n\t\t\tlabel = "e10:net";\n\t\t\tpwms = <%s 0x00 0x186a0 0x00>;\n\t\t\tmax-brightness = <0xff>;\n\t\t\tdefault-state = "off";\n\t\t};\n\t};\n\n') % (ph_ab, ph_cd)
src = src.replace(anchor, leds + anchor)
open(sys.argv[2], 'w').write(src)
print("      dts transformado (sdio + pwm-leds; pwm_AO_ab %s, pwm_AO_cd %s)" % (ph_ab, ph_cd))
PYEOF
dtc -q -I dts -O dtb -o "$WORK/meson-g12a-btv-e10.dtb" "$WORK/e10.dts"
mcopy -o -i "$BOOTFS" "$WORK/meson-g12a-btv-e10.dtb" ::/dtb/amlogic/meson-g12a-btv-e10.dtb
cp "$WORK/e10.dts" "$WORK/meson-g12a-btv-e10.dts"
mcopy -o -i "$BOOTFS" "$WORK/meson-g12a-btv-e10.dts" ::/dtb/amlogic/meson-g12a-btv-e10.dts

echo "[4/7] uEnv.txt"
mcopy -o -i "$BOOTFS" ::/uEnv.txt "$WORK/uEnv.txt"
sed -i 's#^FDT=.*#FDT=/dtb/amlogic/meson-g12a-btv-e10.dtb#' "$WORK/uEnv.txt"
grep -q '^FDT=/dtb/amlogic/meson-g12a-btv-e10.dtb' "$WORK/uEnv.txt" || { echo "FDT nao ajustado"; exit 1; }
mcopy -o -i "$BOOTFS" "$WORK/uEnv.txt" ::/uEnv.txt
if [[ -f "$WORK/root/etc/ophub-release" ]]; then
    sed -i "s|^FDTFILE=.*|FDTFILE='meson-g12a-btv-e10.dtb'|" "$WORK/root/etc/ophub-release"
fi

echo "[5/7] modulo 8189fs para $KVER"
install -D -m 644 "$MOD" "$WORK/root/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/8189fs.ko"
depmod -a -b "$WORK/root" "$KVER"
grep -q "8189fs" "$WORK/root/lib/modules/$KVER/modules.dep" || { echo "depmod nao registrou o 8189fs"; exit 1; }
grep -q "024C.*F179\|024c.*f179" "$WORK/root/lib/modules/$KVER/modules.alias" || { echo "alias SDIO do 8189fs ausente"; exit 1; }
install -m 644 "$PKG/8189fs.conf" "$WORK/root/etc/modprobe.d/8189fs.conf"

echo "[6/7] LED de rede (dispatcher do NetworkManager), model_database.conf e e10-release"
install -d "$WORK/root/etc/NetworkManager/dispatcher.d"
cat > "$WORK/root/etc/NetworkManager/dispatcher.d/90-e10-netled" <<'NMEOF'
#!/bin/sh
# BTV Express E10: LED NET verde quando ha conectividade, vermelho quando nao ha
LED=/sys/class/leds/e10:net
[ -w "$LED/brightness" ] || exit 0
MAX="$(cat "$LED/max_brightness" 2>/dev/null || echo 1)"
case "$(nmcli -g STATE general 2>/dev/null)" in
  connected*) echo "$MAX" > "$LED/brightness" ;;
  *)          echo 0 > "$LED/brightness" ;;
esac
NMEOF
chmod 755 "$WORK/root/etc/NetworkManager/dispatcher.d/90-e10-netled"
MDB="$WORK/root/etc/model_database.conf"
if [[ -f "$MDB" ]] && ! grep -q "meson-g12a-btv-e10.dtb" "$MDB"; then
    printf '%s\n' "309     :BTV-Express-E10                               :s905x2   :meson-g12a-btv-e10.dtb                   :u-boot-x96max.bin            :x96max-u-boot.bin.sd.bin            :NA                              :2+8G,100Mb-Nic,WiFi-RTL8189FTV             :stable/all            :amlogic     :meson-g12a   :uEnv.txt        :CienTec-UNIFAL                                       :s905x2-btv-e10            :no" >> "$MDB"
fi
cat > "$WORK/root/etc/e10-release" <<EOF
E10_IMAGE_BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
E10_BASE_IMAGE=$(basename "$BASE")
E10_BASE_SHA256=$(sha256sum "$BASE" | cut -c1-64)
E10_KERNEL=$KVER
E10_MODULE_SHA256=$(sha256sum "$MOD" | cut -c1-64)
E10_DTB=meson-g12a-btv-e10.dtb (sei510 + bias-pull-up sdio, sem sd-uhs-sdr50, sem cap-sd-highspeed, max-frequency 25 MHz, pwm-leds POWER=PWM_AO_A/GPIOAO_11 NET=PWM_AO_C/GPIOAO_4, 10 kHz)
E10_NOTES=driver 8189fs branch rtl8189fs + patch E10 (fatiamento de FIFO com endereco fixo)
EOF

echo "[7/7] fechando"
sync
umount "$WORK/root"; losetup -d "$LOOP"; LOOP=""
if [[ -z "$OUT" ]]; then
    OUT="$(basename "$BASE" .img.gz | sed "s/_amlogic_s905x2_/_amlogic_s905x2-btv-e10_/").img.gz"
    [[ "$OUT" == "$(basename "$BASE")" ]] && OUT="$(basename "$BASE" .img.gz)_btv-e10.img.gz"
fi
[[ "$(readlink -f "$OUT")" == "$(readlink -f "$BASE")" ]] && { echo "saida coincide com a imagem base; escolha outro nome"; exit 1; }
gzip -c -6 "$IMG" > "$OUT"
sha256sum "$OUT" | tee "$OUT.sha"
rm -f "$IMG"
echo "pronto: $OUT"
