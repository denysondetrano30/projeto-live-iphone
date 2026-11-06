# Projeto Live — app de câmera para iPhone

App que transforma um iPhone (mesmo antigo) em câmera para a transmissão do culto.
Faz parte do projeto [projeto-live](https://github.com/denysondetrano30/projeto-live),
uma versão do OBS Studio feita para igrejas.

## O que a versão 0.3 faz

- Aparece sozinho na rede (Bonjour, serviço `_projetolive._tcp`) com um nome fixo,
  por exemplo "Câmera iPhone 4F2A". A fonte "Celular (Projeto Live)" do nosso OBS acha o iPhone por esse nome.
- Manda a imagem da câmera para o OBS do PC pelo Wi-Fi, em Full HD (1920x1080, 30 quadros, 6 Mbps),
  usando o protocolo SRT. Ainda sem áudio.
- Mostra no topo o endereço para colocar no OBS e se o PC está conectado (bolinha verde).
- Usa a lente de zoom nos aparelhos que têm (como o iPhone 8 Plus): o 2x e o 3x ficam mais nítidos.
- Funciona só com o celular deitado, porque a transmissão é 16:9. O vertical 9:16 é recortado no PC.
- Grade de terços e recorte vertical 9:16, zoom 1x/2x/3x ou pinça, toque para focar,
  botão "Travar" (foco, exposição e balanço de branco) e tela sempre acesa.

Funciona a partir do iOS 16 (iPhone 8 e mais novos).

## Como receber a imagem no OBS

No nosso OBS: adicione a fonte **Celular (Projeto Live)** e escolha o iPhone na lista.

Em qualquer outro OBS, dá para receber à mão:

1. iPhone e PC na mesma rede Wi-Fi (ou o PC no cabo do mesmo roteador).
2. Abra o app. No topo aparece algo como `srt://192.168.0.15:9000`.
3. No OBS, adicione uma **Fonte de mídia**, desmarque **Arquivo local** e preencha:
   - **Entrada:** o endereço que aparece no iPhone, por exemplo `srt://192.168.0.15:9000`
   - **Formato de entrada:** `mpegts`
4. A bolinha no iPhone fica verde e a imagem aparece no OBS.

Se o OBS desconectar, o iPhone volta a esperar sozinho.

## Como o app é montado

Não precisa de Mac. A cada envio para a branch `main`, o GitHub Actions monta o app
num Mac na nuvem (veja `.github/workflows/montar-app.yml`) e guarda o arquivo
`ProjetoLive.ipa` na página da compilação, em **Artifacts**.

O projeto do Xcode é gerado na hora pelo [XcodeGen](https://github.com/yonaskolb/XcodeGen),
a partir do arquivo `project.yml`. O envio por SRT usa a biblioteca
[HaishinKit](https://github.com/HaishinKit/HaishinKit.swift) 2.3.0 (licença BSD-3), que inclui a libsrt (licença MPL 2.0).

## Como instalar no iPhone pelo Windows

1. Baixe o `ProjetoLive.ipa` em **Actions → última compilação → Artifacts** e descompacte o .zip.
2. Instale o [Sideloadly](https://sideloadly.io/) e, se pedir, o iTunes do site da Apple
   (não o da Microsoft Store).
3. Ligue o iPhone no PC pelo cabo, abra o Sideloadly, arraste o `.ipa` e entre com o seu Apple ID.
4. No iPhone, ative o **Modo de Desenvolvedor** em **Ajustes → Privacidade e Segurança → Modo de Desenvolvedor**
   (o iPhone reinicia). A opção aparece depois da primeira instalação.
5. Autorize o seu Apple ID em **Ajustes → Geral → VPN e Gerenciamento de Dispositivo**.

Com Apple ID gratuito, o app vale por 7 dias. Depois é só instalar de novo.
