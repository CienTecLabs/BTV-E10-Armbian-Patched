# Imagem Armbian pronta para a BTV Express E10 — kit de geração

O kit transforma a imagem oficial do ophub para S905X2 numa imagem da E10 com WiFi funcional,
sem nenhum passo manual depois de gravar o cartão. O procedimento foi executado e verificado
em 16/09/2026 sobre `Armbian_26.11.0_amlogic_s905x2_bookworm_6.12.109_server_2026.09.14.img.gz`.

Por que um script e não a imagem pronta: a imagem tem 845 MB comprimidos; o script gera o
mesmo resultado em uns 5 minutos a partir do download oficial, deixa registro do que foi
injetado (`/etc/e10-release`) e serve para qualquer versão futura da série 6.12, bastando
recompilar o módulo (ver "Atualização de kernel").

## Conteúdo

| Arquivo | Função |
|---|---|
| `e10-make-image.sh` | Gera a imagem. Roda em Ubuntu x86_64 (WSL serve), como root |
| `8189fs-6.12.109-ophub.ko` | Driver RTL8189FTV com o patch E10, para o kernel da imagem oficial de 14/09/2026 |
| `8189fs-6.12.110-ophub.ko` | Idem, para o kernel 6.12.110 (o testado na bancada; ainda sem imagem oficial) |
| `8189fs.conf` | Opções do módulo (economia de energia do rádio desligada, sem `wlan1`, log só de erros) |
| `8189fs-e10.patch` | Patch sobre a branch `rtl8189fs` de jwrdegoede/rtl8189ES_linux, para recompilar |
| `SHA256SUMS` | Conferência |

## O que a imagem gerada tem a mais que a oficial

1. `/boot/dtb/amlogic/meson-g12a-btv-e10.dtb` (e o `.dts`), gerado a partir do
   `meson-g12a-sei510.dtb` da própria imagem: `bias-pull-up` no grupo `sdio`, sem
   `sd-uhs-sdr50`, sem `cap-sd-highspeed`, `max-frequency = 25000000`, `model` identificando a E10.
2. `FDT=/dtb/amlogic/meson-g12a-btv-e10.dtb` em `/boot/uEnv.txt` e `FDTFILE` em `/etc/ophub-release`.
3. `8189fs.ko` em `/lib/modules/<kver>/kernel/drivers/net/wireless/realtek/`, com `depmod`
   feito (o módulo carrega sozinho pelo alias SDIO `024c:f179`).
4. `/etc/modprobe.d/8189fs.conf`.
5. Entrada `309 BTV-Express-E10` em `/etc/model_database.conf`, para o `armbian-install`
   gravar na eMMC com o DTB certo.
6. `/etc/e10-release` com data, imagem base, kernel e sha256 do módulo.

Nada mais é alterado: usuários, senha (`root`/`1234` no primeiro login, como no Armbian),
serviços e o `armbian-install` do ophub ficam como na imagem oficial.

## Gerar a imagem (Ubuntu/WSL)

```
sudo apt install -y device-tree-compiler kmod mtools gzip
wget https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_bookworm_arm64_server_2026.09/Armbian_26.11.0_amlogic_s905x2_bookworm_6.12.109_server_2026.09.14.img.gz
sha256sum Armbian_26.11.0_amlogic_s905x2_bookworm_6.12.109_server_2026.09.14.img.gz
# esperado: befd594bd1cb765f170d42ef2a1f061dcd2d7b157fba2e4f182c20a8721e6898
sudo bash e10-make-image.sh Armbian_26.11.0_amlogic_s905x2_bookworm_6.12.109_server_2026.09.14.img.gz .
```

Sai `Armbian_26.11.0_amlogic_s905x2-btv-e10_bookworm_6.12.109_server_2026.09.14.img.gz` e o
`.sha`. Precisa de uns 5 GB livres (imagem descompactada de 3,7 GB mais a saída). O sha da
imagem final varia a cada geração (há data em `/etc/e10-release`); o que deve bater é o
conteúdo: DTB `98db5ce2…`, módulo 6.12.109 `c56c5301…`.

Grave no microSD com balenaEtcher ou Rufus (modo dd). Cartão de 8 GB ou mais.

## Primeira vez em cada E10 (com Android de fábrica)

1. Cartão inserido, segurar o botão UPDATE, ligar a alimentação, soltar após uns 5 s. O
   U-Boot de fábrica executa o `aml_autoscript` do cartão e passa a bootar do cartão sempre que
   houver um inserido. Sem cartão, volta ao Android normalmente.
2. Primeiro login: `root` / `1234`; o Armbian pede senha nova e cria um usuário.
3. Conferir: `cat /proc/device-tree/model` (deve dizer BTV Express E10),
   `cat /sys/kernel/debug/mmc0/ios` (25 MHz, legacy, 4 bits), `ip link` (só `wlan0`),
   `nmcli dev wifi list`.
4. Para gravar na eMMC (apaga o Android): `armbian-install`, escolher `309` (BTV-Express-E10),
   sistema de arquivos `ext4`. Não usar `-m yes`: o bootloader de fábrica fica na eMMC e só
   encadeia o U-Boot mainline, que é o arranjo validado. Depois `poweroff`, tirar o cartão, ligar.

Desktop: a imagem é server. Para XFCE: `armbian-config` -> System -> Desktop, ou
`apt install task-xfce-desktop lightdm`. A aceleração 3D (Panfrost, Mali-G31) já vem no kernel;
decodificação de vídeo por hardware não é utilizável nesse kernel, vídeo 1080p em navegador
roda por software.

## Atualização de kernel

Qualquer `armbian-update` troca o kernel e o módulo deixa de existir para a versão nova. O
DTB tem nome próprio e sobrevive, mas confira `FDT=` em `/boot/uEnv.txt`. Para uma versão
nova `X.Y.Z-ophub`:

```
git clone -b rtl8189fs https://github.com/jwrdegoede/rtl8189ES_linux.git
cd rtl8189ES_linux && git apply 8189fs-e10.patch
make -j4 ARCH=arm64 KSRC=/lib/modules/X.Y.Z-ophub/build      # nativo na E10 (com headers)
install -D -m 644 8189fs.ko /lib/modules/X.Y.Z-ophub/kernel/drivers/net/wireless/realtek/8189fs.ko
depmod -a X.Y.Z-ophub
```

Depois, renomear o `.ko` para `8189fs-X.Y.Z-ophub.ko`, colocar no kit e gerar a imagem nova a
partir da imagem oficial correspondente. A alternativa definitiva é empacotar o driver em
DKMS (pendência) ou incorporar a E10 ao build do ophub por fork com GitHub Actions
(`model_database.conf` + arquivos em `armbian-files`), o que dispensa este script.

## O que ainda não foi validado

- A imagem gerada foi verificada por inspeção (arquivos, `depmod`, alias, DTB idêntico ao
  testado). O teste de boot e WiFi da imagem em si, a partir do cartão, ainda precisa ser feito
  numa E10: idealmente na segunda unidade, com Android intacto, que também serve de controle.
- O kernel da imagem é 6.12.109; a bancada foi testada com 6.12.110. O DTB `sei510` é idêntico
  nas duas versões e o driver foi compilado contra os headers de cada uma.
- Estabilidade longa (24 h) e reconexão após reinício do AP.
