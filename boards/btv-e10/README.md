# BTV Express E10

- SoC Amlogic S905X2 (G12A), 2 GB LPDDR4, eMMC 8 GB, WiFi RTL8189FTV (SDIO 024c:f179) em `sd_emmc_a`, Ethernet 100 Mbit (PHY interno)
- Imagem base: ophub `amlogic_s905x2` (serie 6.12), DTB derivado do `meson-g12a-sei510.dtb`
- `armbian-install`: modelo `309` (BTV-Express-E10), sem `-m yes`
- Detalhes das causas e da matriz de testes do WiFi em `docs/WIFI.md`

Arquivos desta pasta:

- `8189fs.conf`: opcoes do modulo (`/etc/modprobe.d/8189fs.conf` na imagem)

O DTB nao fica versionado como binario: `scripts/e10-make-image.sh` o gera a partir do `sei510` da
propria imagem base (model, `bias-pull-up` no grupo `sdio`, sem `sd-uhs-sdr50`, sem
`cap-sd-highspeed`, `max-frequency = 25000000`), e publica o `.dts` resultante junto com a release.
