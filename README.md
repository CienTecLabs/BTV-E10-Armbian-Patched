# TV Box 2.0 - Geração e Patch de ROM - BTV E10

Geracao reproduzivel da imagem Armbian (base ophub) para as TV Boxes descaracterizadas do projeto
(parceria UNIFAL-MG x Receita Federal).

Placa suportada: BTV Express E10 (Amlogic S905X2).

## Sobre o projeto
Este projeto possui relação direta com o repositório https://github.com/lnrddev/tvbox, sob orientação do Prof. Leonardo Henrique Soares Damasceno, do Campus Poços de Caldas da Unifal-MG e o Make Roots Lab.

O [CienTec](https://www.instagram.com/cenaccientec/) (através da sua divisão de tecnologia "CienTec Labs") atua como um parceiro técnico no projeto.

Mais informações podem ser consultadas diretamente no [repositório do projeto](https://github.com/lnrddev/tvbox).

## Sobre este repositório
Este repositório visa gerar uma imagem com patch de correção para utilização do adaptador de WiFi da placa BTV E10, que até então, possuia um problema de configuração que impedia a utilização do módulo WiFi em imagens Armbian.

### Problemas identificados e corrigidos:
#### 1. Faltava o driver.
O chip de WiFi da E10 (Realtek RTL8189FTV) não tem driver no kernel Linux oficial; depende de um driver externo, e as imagens do ophub que o projeto usava não o incluíam. Sem ele, nada funcionaria mesmo que o resto estivesse certo. Corrigimos compilando esse driver para o kernel da imagem e incluindo o arquivo nela.

#### 2. O "mapa" (DTB) da placa pedia uma velocidade que ela não aguenta.
O Linux precisa de um arquivo (DTB) descrevendo o hardware, e o projeto usava o de uma placa parecida, a SEI510. Esse arquivo manda o barramento SDIO, o fio entre o processador e o chip de WiFi, rodar a 100 MHz em modo de alta velocidade. Na E10, que é uma placa de fabricação barata, isso dá erro de comunicação logo na partida: o chip nem chegava a ser detectado. Testando várias combinações, descobrimos que ela só é confiável a 25 MHz e no modo de velocidade padrão. Corrigimos gerando um DTB próprio da E10 com essa configuração.

#### 3. O driver não sabia conviver com um limite desse processador (fatiamento de FIFO).
Resolvidos os dois anteriores, o WiFi conectava mas perdia parte dos dados: o processador S905X2 só consegue transferir 1,5 KB por vez nesse barramento, e o driver Realtek pedia blocos de até 16 KB, deixando o Linux dividir em pedaços. Só que, ao dividir, o Linux altera um campo que para o chip Realtek não é endereço, é instrução; os pedaços seguintes chegavam ao chip com a instrução errada e vinham corrompidos. Corrigimos alterando o driver para ele mesmo dividir em pedaços de 1,5 KB, repetindo a instrução certa em cada um. É a mesma técnica que o driver oficial dos Realtek mais novos já usa.

### Solução

Este repositório fica reponsável por gerar uma imagem já com o patch aplicado, usando o driver compilado do RTL8189FTV e os ajustes necessários no DTB.

Testado no Kernel 6.12.109.

## Como gerar uma imagem

GitHub Actions, aba *Actions* -> *Build BTV E10 image* -> *Run workflow*. Parametros:

| Parametro | Padrao | Observacao |
|---|---|---|
| `kver` | `6.12.109` | versao do kernel ophub; precisa existir em [ophub/kernel](https://github.com/ophub/kernel/releases/tag/kernel_stable) (so as 4 ultimas de cada serie ficam publicadas) |
| `base_release` | `Armbian_bookworm_arm64_server_2026.09` | tag da release em [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian/releases) |
| `base_image` | `Armbian_26.11.0_amlogic_s905x2_bookworm_6.12.109_server_2026.09.14.img.gz` | imagem `amlogic_s905x2` com o mesmo kernel de `kver` |
| `base_sha256` | vazio | se informado, o build falha quando o download não confere |
| `publish` | nao | cria uma release `build-N` com os artefatos |

Push de uma tag `vX.Y.Z` em `master` gera e publica a release `vX.Y.Z` com os padroes acima.

O que o workflow faz: 
1. compila o driver `8189fs` (branch `rtl8189fs` de jwrdegoede/rtl8189ES_linux, commit
fixado em `scripts/build-8189fs.sh`) com o patch de `drivers/rtl8189fs/` contra os headers do kernel
escolhido;
2. baixa a imagem oficial;
3. roda `scripts/e10-make-image.sh`, que injeta DTB, modulo (com
`depmod`), `modprobe.d`, entrada `309` no `model_database.conf` e `/etc/e10-release`;
4. publica imagem, `.sha`, modulo, patch, DTB/DTS e `SHA256SUMS`.

Localmente (Ubuntu/WSL x86_64): os mesmos dois scripts, na mesma ordem. `docs/IMAGEM.md` tem o passo a passo.

## Estrutura

```
.github/workflows/build-image.yml   workflow
boards/btv-e10/                     arquivos especificos da placa (modprobe.d, notas)
drivers/rtl8189fs/                  patch do driver (correcao do fatiamento de FIFO em hosts com max_req_size pequeno)
scripts/build-8189fs.sh             compila o modulo contra headers do ophub (cross, x86_64)
scripts/e10-make-image.sh           transforma a imagem oficial na imagem da E10
docs/WIFI.md                        causas raiz, matriz de testes, reproducao
docs/IMAGEM.md                      uso da imagem, primeiro boot, eMMC, atualizacao de kernel
```

## Atualizar para um kernel novo

1. Conferir em ophub/kernel se a versao existe e em ophub/amlogic-s9xxx-armbian se ha imagem
   `amlogic_s905x2` com ela.
2. Rodar o workflow com `kver`, `base_release` e `base_image` novos. Se o driver nao compilar contra
   o kernel novo, atualizar `DRIVER_REF` em `scripts/build-8189fs.sh` para um commit mais recente da
   branch `rtl8189fs` (o repositorio recebe correcoes para cada serie estavel).
3. Testar a imagem numa E10 (boot por cartao, `cat /sys/kernel/debug/mmc0/ios`, `ip link`,
   download grande sem `FAIL(-84)`/`parse fail` no `dmesg`) antes de publicar como `vX.Y.Z`.

## Estado

- Validado na bancada com 6.12.110; a imagem publicada usa o 6.12.109 (ultima imagem oficial);
  DTB `sei510` identico nas duas versoes, modulo compilado para cada uma.
- Pendente: teste da imagem gerada numa segunda E10, teste de estabilidade longo, desktop e
  aplicativos (fase 2), cartao de instalacao automatica (fase 3).

## Autoria
- José Lucio Zancan Junior <jose.lucio@cientec.org.br>, <jose.lucio@sou.unifal-mg.edu.br>
- CienTec Labs (Infraestrutura técnica) <labs@cientec.org.br>
- Prof. Leonardo Henrique Soares Damasceno <https://github.com/lnrddev>
- Anthropic Claude Fable 5.1 (Busca de Referenciais Teóricos, Formulação da Documentação e Consolidação de Informações)

## Disclaimer
Não nos resposabilizamos por dispositivos brickados, corrupção de cartões SD, guaxinins radicalizados, rebaixamento do Vasco e eventos similares.

As informações fornecidas neste repositório destinam-se apenas a fins informativos gerais.

O CienTec, CienTec Labs e os demais autores aqui listados não assumem qualquer responsabilidade por erros ou omissões no conteúdo ou por quaisquer ações tomadas com base nas informações fornecidas.

Links para sites externos são disponibilizados por conveniência e não implicam endosso.

O CienTec, CienTec Labs e os demais autores aqui listados não se responsabilizam pela precisão, confiabilidade ou conteúdo de sites de terceiros.

O uso deste repositório e do conteúdo do mesmo é de sua inteira responsabilidade, e o CienTec, CienTec Labs e os demais autores aqui listados não respondem por quaisquer danos decorrentes de sua utilização.

Recomendamos que utilize um dispositivo que possa ser extraviado sem nenhum prejuízo maior, sob sua responsabilidade.

### Leia as documentações e comentários!