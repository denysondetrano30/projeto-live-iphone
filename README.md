# Projeto Live — app de câmera para iPhone

App que transforma um iPhone (mesmo antigo) em câmera para a transmissão do culto.
Faz parte do projeto [projeto-live](https://github.com/denysondetrano30/projeto-live),
uma versão do OBS Studio feita para igrejas.

## O que a versão 0.1 faz

- Mostra a câmera traseira em tela cheia, em pé ou deitado.
- Grade de terços e, com o celular deitado, o recorte vertical 9:16 do meio da imagem.
- Zoom nos botões 1x, 2x e 3x, ou com pinça na tela.
- Toque na tela para focar e medir a luz naquele ponto.
- Botão "Travar", que segura foco, exposição e balanço de branco.
- A tela não apaga enquanto o app está aberto.

Ainda não envia a imagem para o PC. Isso vem na próxima versão.

Funciona a partir do iOS 16 (iPhone 8 e mais novos).

## Como o app é montado

Não precisa de Mac. A cada envio para a branch `main`, o GitHub Actions monta o app
num Mac na nuvem (veja `.github/workflows/montar-app.yml`) e guarda o arquivo
`ProjetoLive.ipa` na página da compilação, em **Artifacts**.

O projeto do Xcode é gerado na hora pelo [XcodeGen](https://github.com/yonaskolb/XcodeGen),
a partir do arquivo `project.yml`.

## Como instalar no iPhone pelo Windows

1. Baixe o `ProjetoLive.ipa` em **Actions → última compilação → Artifacts** e descompacte o .zip.
2. Instale o [Sideloadly](https://sideloadly.io/) e, se pedir, o iTunes do site da Apple
   (não o da Microsoft Store).
3. Ligue o iPhone no PC pelo cabo, abra o Sideloadly, arraste o `.ipa` e entre com o seu Apple ID.
4. No iPhone, ative o **Modo de Desenvolvedor** em **Ajustes → Privacidade e Segurança → Modo de Desenvolvedor**
   (o iPhone reinicia). A opção aparece depois da primeira instalação.
5. Autorize o seu Apple ID em **Ajustes → Geral → VPN e Gerenciamento de Dispositivo**.

Com Apple ID gratuito, o app vale por 7 dias. Depois é só instalar de novo.
