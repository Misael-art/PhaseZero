# Web App Icons (curados)

Ícones de identidade dos atalhos de web app criados por `Ensure-BootstrapWebAppShortcut`.

## Como funciona (cascata resiliente)
`Resolve-BootstrapWebAppIconLocation` escolhe o ícone nesta ordem, e **nunca falha** o atalho:

1. **Curado** — `assets/webapp-icons/<slug>.ico` (este diretório; offline, confiável). **Primário.**
2. **Cache** — `%LOCALAPPDATA%\PhaseZero\ai-tools\...\webapp-icons\<host>.ico` (favicon já baixado).
3. **Favicon** — baixa `https://<host>/favicon.ico` e valida os magic bytes de ICO.
4. **Fallback** — ícone do navegador (comportamento legado).

Para curar um ícone, **basta colocar o arquivo `.ico` com o nome do slug abaixo** nesta pasta.
Não há etapa de build: o componente usa o arquivo diretamente.

## Requisitos do arquivo
- Formato **`.ico`** real (não PNG/JPG renomeado; a validação por magic bytes rejeita arquivos falsos).
- Recomendado conter tamanhos 16/32/48/256 px.
- Use o **logotipo oficial do app** apenas se você tiver direito de uso; caso contrário, deixe a cascata cair no favicon do próprio site.

## Slugs esperados (nome do arquivo)

| Web App | Arquivo | Host (favicon fallback) |
|---|---|---|
| Amazon Prime Video | `amazon-prime-video.ico` | www.primevideo.com |
| Bolt.new | `bolt-new.ico` | bolt.new |
| Discord | `discord.ico` | discord.com |
| Dropbox | `dropbox.ico` | www.dropbox.com |
| Gemini | `gemini.ico` | gemini.google.com |
| Gmail | `gmail.ico` | mail.google.com |
| Google Agenda | `google-agenda.ico` | calendar.google.com |
| Google AI Studio | `google-ai-studio.ico` | aistudio.google.com |
| Google Docs | `google-docs.ico` | docs.google.com |
| Google Drive | `google-drive.ico` | drive.google.com |
| Google Keep | `google-keep.ico` | keep.google.com |
| Google Meet | `google-meet.ico` | meet.google.com |
| Google Sheets | `google-sheets.ico` | sheets.google.com |
| Google Slides | `google-slides.ico` | slides.google.com |
| iCloud | `icloud.ico` | www.icloud.com |
| Kimi | `kimi.ico` | www.kimi.com |
| Lovable.dev | `lovable-dev.ico` | lovable.dev |
| Manus | `manus.ico` | manus.im |
| MEGA | `mega.ico` | mega.nz |
| Netflix | `netflix.ico` | www.netflix.com |
| Notion | `notion.ico` | www.notion.so |
| Office Excel | `office-excel.ico` | www.office.com |
| Office PowerPoint | `office-powerpoint.ico` | www.office.com |
| Office Word | `office-word.ico` | www.office.com |
| OneDrive | `onedrive.ico` | onedrive.live.com |
| Photopea | `photopea.ico` | www.photopea.com |
| Slack | `slack.ico` | slack.com |
| Spotify | `spotify.ico` | open.spotify.com |
| Telegram Web | `telegram-web.ico` | web.telegram.org |
| Trello | `trello.ico` | trello.com |
| v0.dev | `v0-dev.ico` | v0.dev |
| WhatsApp Web | `whatsapp-web.ico` | web.whatsapp.com |
| Xiaomi AI Studio | `xiaomi-ai-studio.ico` | aistudio.xiaomimimo.com |
| YouTube | `youtube.ico` | www.youtube.com |
| Z.ai | `z-ai.ico` | chat.z.ai |
| Zoom | `zoom.ico` | zoom.us |

> O slug é derivado do DisplayName: minúsculas, não-alfanuméricos viram `-`, bordas aparadas.
> Itens sem `.ico` curado funcionam normalmente via favicon.
