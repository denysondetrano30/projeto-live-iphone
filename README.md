# Projeto Live — app de câmera para iPhone

App que transforma um iPhone (mesmo antigo) em câmera para a transmissão do culto.
Faz parte do projeto [projeto-live](https://github.com/denysondetrano30/projeto-live),
uma versão do OBS Studio feita para igrejas.

## O que a versão 0.8 faz

- **Intercom.** O botão **Segure para falar** leva a voz do operador ao fone do diretor e aos outros
  celulares (canal geral). O diretor fala com todos ou só com uma câmera pelo painel do OBS, e no
  alto da tela aparece quem está falando. O som só toca com fone de ouvido; sem fone, o app avisa.
  O microfone só é usado enquanto o botão estiver apertado, e essa voz nunca vai para a live.
  Voz em 16 kHz sem compressão: pelo Wi-Fi vai por UDP (porta que o OBS informa no canal de
  controle); pelo cabo, pela porta 9012 do app.
- **Avisos do diretor.** No OBS, o painel "Diretor (Projeto Live)" (menu Painéis) e os atalhos de
  teclado mandam avisos para cada câmera: "Abre", "Fecha", "Foca no pregador", "Você está no ar"
  ou um texto livre. O aviso aparece grande na tela do iPhone, que vibra se a câmera não estiver no
  ar (no ar, a vibração tremeria a imagem). O operador toca em **Entendi** e o diretor vê a
  confirmação no painel. Pelo cabo, os avisos usam a porta 9011.
- **Aviso de "no ar".** Quando a fonte "Celular" desta câmera entra no Programa do OBS, a tela do
  iPhone ganha uma borda vermelha e o selo **NO AR**. Pelo Wi-Fi, o aviso vem por um canal de
  controle (TCP, na mesma porta do vídeo, com prova da senha do QR code por HMAC-SHA256, sem mandar
  a senha pela rede). Pelo cabo USB, vem pelo próprio cabo. No plano B (sem pareamento) não há aviso.
- **Cabo USB.** No OBS, escolha "Cabo USB (iPhone)" na fonte "Celular". O app espera na porta 9010
  e manda o vídeo em H.264/MPEG-TS pelo cabo (no Windows, pelo serviço Apple Mobile Device, que vem com o iTunes ou com o app Dispositivos Apple).
- **Pareamento por QR code.** No OBS, a fonte "Celular (Projeto Live)" mostra um QR code.
  No app, toque em **Parear** e aponte para ele. A partir daí o iPhone liga sempre para aquela
  fonte, com a senha dela, e reconecta sozinho se cair ou se o app for reaberto.
- Manda a imagem da câmera para o OBS pelo Wi-Fi, em Full HD (1920x1080, 30 quadros, 6 Mbps),
  usando o protocolo SRT com senha. Ainda sem áudio.
- Usa a lente de zoom nos aparelhos que têm (como o iPhone 8 Plus): o 2x e o 3x ficam mais nítidos.
- Funciona só com o celular deitado, porque a transmissão é 16:9. O vertical 9:16 é recortado no PC.
- Grade de terços e recorte vertical 9:16, zoom 1x/2x/3x ou pinça, toque para focar,
  botão "Travar" (foco, exposição e balanço de branco) e tela sempre acesa.

Funciona a partir do iOS 16 (iPhone 8 e mais novos).

## Plano B: sem pareamento

Sem pareamento, o iPhone espera na porta 9000 e mostra o endereço no topo
(por exemplo `srt://192.168.0.15:9000`). No nosso OBS, digite esse endereço no campo
"Plano B" da fonte "Celular". Em qualquer outro OBS, use uma **Fonte de mídia**
sem "Arquivo local", com a **Entrada** `srt://IP-DO-IPHONE:9000` e o **Formato de entrada** `mpegts`.

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
