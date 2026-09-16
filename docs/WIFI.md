# BTV Express E10 (Amlogic S905X2) — WiFi RTL8189FTV em Armbian (ophub)

Estado em 16/09/2026: WiFi funcional, sem erros de barramento, com agregação de recepção
ligada e MTU 1500. Download de 110 MB e upload de 30 MB sem nenhum `FAIL(-84)` nem
`parse fail` no `dmesg`.

## Hardware relevante

| Item | Identificação |
|---|---|
| SoC | Amlogic S905X2 (família G12A), Mali-G31 MP2 |
| RAM | CXMT CXDB4ABAM-MJ, LPDDR4, 2 GB (BL2 treina a 1392 MHz) |
| Armazenamento | eMMC 8 GB (SCY E08GDSGF1ABE00, CID `SCA08G`) |
| WiFi | Realtek RTL8189FTV, SDIO, 802.11 b/g/n 2,4 GHz, 1T1R, sem Bluetooth; SDIO ID 024c:f179 |
| Barramento do WiFi | `sd_emmc_a` (`mmc@ffe03000`), com `amlogic,dram-access-quirk` (buffer SRAM de 1536 bytes) |
| Enable do WiFi | GPIOX_6 (ativo alto); host-wake em GPIOX_7; clock 32 kHz em PWM_E (não usado pelo Realtek) |
| Ethernet | PHY interno do SoC, RMII, 100 Mbit/s; BT16B03 é só o transformador do RJ45 |
| UART de console | pads VCC/RX/TX/GND, 3,3 V, 115200 8N1 |
| DTB Android de fábrica | `g12a_u212_2g` (referência Amlogic U212), kernel vendor 4.9.113, Android 9 |

## Causas raiz encontradas (três, independentes)

1. **Driver ausente.** Os kernels do ophub não trazem o driver `8189fs` (out-of-tree,
   jwrdegoede/rtl8189ES_linux, branch `rtl8189fs`). Sem ele nada acontece.

2. **Modo high-speed do SDIO não funciona nessa placa com o mainline.** O `meson-gx-mmc`
   usa fase de amostragem fixa nos modos legacy e SD high-speed (a calibração só roda em
   SDR50/104/HS200). Em high-speed, o 8189FTV muda a temporização de saída e o host passa a
   amostrar na transição: erro de CRC nas leituras, independente da frequência (12,5 MHz erra
   tanto quanto 25). Em default-speed (25 MHz, sem `cap-sd-highspeed`) o CRC zera.
   O DTB `meson-g12a-sei510.dtb`, usado como base, pede `sd-uhs-sdr50` a 100 MHz e nem
   enumera o chip (`mmc0: error -84 whilst initialising SDIO card`).

3. **Fatiamento das transferências do FIFO.** O barramento A da G12A só transfere 1536 bytes
   por requisição (SRAM, `dram-access-quirk`). O core SDIO do kernel divide um agregado de
   até 16 KB em vários CMD53 e incrementa o endereço a cada pedaço. No protocolo Realtek o
   "endereço" do FIFO carrega o tamanho (TX) ou o número de sequência (RX): cada pedaço
   subsequente chegava ao chip com um comando diferente. Resultado: descritores corrompidos com
   CRC válido (`rtw_hal_c2h_pkt_pre_hdl parse fail`), ~5 agregados perdidos por MB, vazão
   dez vezes menor. O `rtw88` mainline fatia manualmente e repete o mesmo endereço; o
   `8189fs` não fazia isso. O patch `8189fs-e10.patch` corrige `sdio_read_port` e
   `sdio_write_port`.

Também confirmado, sem efeito decisivo: `bias-pull-up` nos pinos SDIO (é o que o kernel
vendor usa; o sei510 usa `bias-disable`) reduziu um pouco a taxa de erro em high-speed e foi
mantido no DTB final.

## Matriz de testes (download do mesmo arquivo, contagens no `dmesg`)

| Config | CRC (`FAIL(-84)`) | `parse fail` | Observação |
|---|---|---|---|
| sei510 original (100 MHz, SDR50) | não enumera | — | `error -84 whilst initialising` |
| 25 MHz HS, 4 bits | contínuo | sim | ~360 kB/s |
| 25 MHz DS, 4 bits | 0 | ~3/MB | |
| 12,5 MHz HS, 4 bits | ~10/MB | ~2/MB | pior que 25 MHz: não é setup time |
| 25 MHz HS, pull-up | ~8/MB | ~1/MB | |
| 25 MHz HS, 1 bit | ~9/MB | ~2/MB | mesma taxa: não é DAT1-3 |
| 25 MHz DS, pull-up, 4 bits | 0 | ~5/MB | |
| 25 MHz DS, pull-up, 1 bit | 0 | ~5/MB | independe da largura |
| DS + agregação desligada + MTU 1200 | 0 | 0 | 1,9 MB/s: fatiamento confirmado |
| **DS + patch de endereço fixo, agregação ligada, MTU 1500** | **0** | **0** | **2,2 MB/s down, 0,97 MB/s up (limitado pelo link)** |

## Conteúdo do pacote

| Arquivo | Função |
|---|---|
| `meson-g12a-btv-e10.dtb` / `.dts` | DTB definitivo. Base: `meson-g12a-sei510.dtb` do kernel 6.12.110-ophub. Diferenças: `model`, `bias-pull-up` no grupo `sdio`, sem `sd-uhs-sdr50`, sem `cap-sd-highspeed`, `max-frequency = 25000000` no `mmc@ffe03000` |
| `8189fs.ko` | Módulo para `6.12.110-ophub` (vermagic `6.12.110-ophub SMP preempt mod_unload aarch64`), branch `rtl8189fs` commit `13bbdbc` (11/09/2026) + `8189fs-e10.patch` |
| `8189fs-e10.patch` | Patch cumulativo: fatiamento com endereço fixo em RX/TX; parâmetro `rtw_sdio_rx_agg_kb` (limiar de agregação RX em KB, 0 desliga; padrão 15, o original) |
| `8189fs.conf` | `/etc/modprobe.d/8189fs.conf`: IPS/LPS desligados, sem interface virtual `wlan1`, log só de erros |
| `e10-install.sh` | Instala tudo acima num Armbian ophub já em 6.12.110 |
| `SHA256SUMS` | Conferência |

## Instalação (Armbian ophub, a partir de uma imagem qualquer da série 6.12)

1. Kernel: colocar `boot-`, `dtb-amlogic-`, `modules-` e `header-6.12.110-ophub.tar.gz`
   (do `6.12.110.tar.gz` em github.com/ophub/kernel, release `kernel_stable`) num diretório
   e rodar `armbian-update` nele. Responder **não** ao reboot.
2. `bash e10-install.sh /diretório/deste/pacote`
3. `reboot`. Conferir: `cat /sys/kernel/debug/mmc0/ios` (25 MHz, legacy, 4 bits),
   `ip link` (só `wlan0`), `dmesg | grep -iE "mmc0|8189"` sem erros.

Qualquer `armbian-update` futuro troca o kernel e exige recompilar o módulo (ou empacotar em
DKMS, ver pendências). O DTB tem nome próprio e sobrevive, mas confira `FDT=` em
`/boot/uEnv.txt`.

## Reprodução do módulo (para outro kernel)

```
git clone -b rtl8189fs https://github.com/jwrdegoede/rtl8189ES_linux.git
cd rtl8189ES_linux && git apply 8189fs-e10.patch
make -j4 ARCH=arm64 KSRC=/lib/modules/$(uname -r)/build      # nativo, com headers instalados
```

Cruzado (x86_64, headers do ophub): o pacote `header-*.tar.gz` traz `scripts/` compilado
para aarch64 e `include/config/auto.conf.cmd` com checagem de toolchain que força
`syncconfig` sem Kconfig disponível. Solução usada: recompilar `scripts/basic/fixdep` e
`scripts/mod/modpost` no host, substituir `auto.conf.cmd` por `deps_config :=`, copiar
`config-*` para `.config`, compilar com `aarch64-linux-gnu-gcc-14` (o kernel usa
`-fmin-function-alignment`, gcc ≥ 14).

## Pendências

- Teste de estabilidade longo (24 h com tráfego e reconexão após reinício do AP).
- Repetir na segunda E10 para confirmar que nada é defeito da unidade da bancada.
- DKMS com o patch, para sobreviver a `armbian-update`.
- Pull request na branch `rtl8189fs` de jwrdegoede/rtl8189ES_linux (a correção serve a
  qualquer host com `max_req_size` pequeno, não só à E10); comentário na issue #1955 do
  ophub/amlogic-s9xxx-armbian (aberta pelo Prof. Leonardo, dez/2023); retorno ao EducaBox
  (IFMS), cuja tabela marca Bluetooth como funcional nessa placa, o que está errado.
- High-speed (50 MHz) exigiria patch no `meson-gx-mmc` para ajustar a fase de recepção
  nesse modo; não é necessário para o uso previsto (o rádio 1x1 802.11n entrega menos que
  os 100 Mbit/s brutos do barramento a 25 MHz).
- `regulatory.db` do Debian não casa com as chaves do kernel ophub: cfg80211 fica no domínio
  mundial (canais 12 e 13 só passivos). Irrelevante para escolas; corrigível na build do kernel.
- Controle remoto IR: keymap `btve-remote-5` (customcode 0x4040) está no DTB de fábrica e pode
  virar `rc_keymap` para o `meson-ir`, que já inicializa.
