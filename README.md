# video-to-image.sh

Converta vídeos em **frames lossless** (PNG ou WebP) no macOS (M1/Apple Silicon) — com filtros inteligentes, deduplicação visual e otimização opcional. Tudo em **um** script.

> ⚡️ Rápido quando você quer, minucioso quando você precisa.

---

## 🔧 O que ele faz

- Instala **Homebrew** (se faltar) e dependências: `ffmpeg`, `oxipng` (e `webp` se você pedir WebP).
- Extrai frames **lossless**:
  - **PNG** (otimizado com `oxipng`, opcional).
  - **WebP lossless** (menor que PNG).
- Evita frames repetidos:
  - Durante a extração: `--unique` (mpdecimate) **ou** `--scene` (detecção de cena).
  - Pós-processo: `--dedupe exact` (hash) ou `--dedupe phash[:N]` (similaridade visual).
- Aceita **vários vídeos** de uma vez.
- Organização dos arquivos:
  - Por padrão: `OUT/<basename_do_video>/frame_000001.png`
  - `--flat`: tudo em `OUT/`, com **prefixo automático** por vídeo (sem sobrescrever).

---

## 🚀 Quick start

```bash
# básico (5 fps, 720p, sem otimização para ser rápido)
FFMPEG_LOGLEVEL=info ./video-to-image.sh --out ./frames --fps 5 --scale -1:720 --no-opt -- -- video1.mp4 video2.mov
```

```bash
# modo “limpo”: menos frames parecidos + dedupe visual
./video-to-image.sh   --out ./frames   --fps 5   --scale -1:720   --unique   --dedupe phash:5   -- -- video.mp4
```

```bash
# só mudanças de cena (ex.: tentará thresholds de 0.10 a 0.05)
./video-to-image.sh   --out ./frames   --scene 0.05~0.10 --scene-step 0.01   -- -- video.mp4
```

---

## 🧪 Uso

```bash
video-to-image.sh --out <DIR> [opções] -- <video1> [video2 ...]
```

### Opções principais

- `--fps N` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Limita a N fps (pós-dedupe, se tiver).
- `--scale WxH` &nbsp;&nbsp;&nbsp;&nbsp;Redimensiona mantendo proporção (ex.: `1280:-1` ou `-1:720`).
- `--start TIME` Começa em `TIME` (ex.: `00:00:05`).
- `--duration D` Duração (ex.: `10` ou `00:00:10`).
- `--unique` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Remove quase-duplicados na extração (`mpdecimate`).
- `--scene T|A~B` Mantém só mudanças de cena (`select='gt(scene,T)'`).
  - Aceita **faixa** `A~B` (tenta de **B para A** com `--scene-step`).
- `--scene-step S` Passo para a faixa de cena (padrão `0.01`).
- `--dedupe MODE` Pós-processo:
  - `exact` — remove apenas **idênticos** (hash).
  - `phash[:N]` — remove **quase-iguais** (visual). `N` default **5**.  
    (3–5 = seguro; 6–8 = agressivo; 9–10 = muito agressivo)
- `--webp` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Frames em **WebP lossless** (menor tamanho).
- `--flat` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Não cria subpastas; usa **prefixo automático** por vídeo.
- `--prefix P` &nbsp;&nbsp;&nbsp;Prefixo manual (ex.: `shot_`).
- `--no-opt` &nbsp;&nbsp;&nbsp;&nbsp;Pula otimização `oxipng` (mais rápido).
- `--debug` &nbsp;&nbsp;&nbsp;&nbsp;Mais logs + comando `ffmpeg`.

> 💡 O script usa aceleração de vídeo do macOS: `-hwaccel videotoolbox`.

---

## 🧭 Padrões de saída

- **Sem `--flat`**:  
  `OUT/<basename_do_video>/frame_000001.png`
- **Com `--flat`**:  
  `OUT/<prefixo_auto>frame_000001.png`  
  O prefixo vem do nome do vídeo (`clip_`, `clip-2_`, …). Nada sobrescreve.

---

## 🥷 Dedupe — qual usar?

| Modo      | Como funciona                           | Vantagens                                             | Desvantagens                      |
| --------- | --------------------------------------- | ----------------------------------------------------- | --------------------------------- |
| **exact** | Hash criptográfico (SHA256) por arquivo | Super rápido; não apaga por engano                    | Só pega 100% idênticos            |
| **phash** | “Perceptual hash” por imagem            | Pega visuais quase iguais (mesmo com bits diferentes) | Mais lento; precisa calibrar `:N` |
| **scene** | `select='gt(scene,T)'` no `ffmpeg`      | Evita gerar repetidos desde a extração                | Se T alto, pode pular coisa útil  |

**Recomendação:** `--dedupe phash:5` no pós-processo (suba para `:6~8` se ainda sobrar redundância). Combine com `--unique` **ou** `--scene` na extração.

---

## 🧰 Exemplos prontos

```bash
# WebP lossless (arquivo menor), 5 fps, 720p, dedupe visual
./video-to-image.sh --out out --webp --fps 5 --scale -1:720 --dedupe phash:6 -- -- a.mp4 b.mp4
```

```bash
# Tudo no mesmo diretório, com prefixo automático por vídeo
./video-to-image.sh --out out --flat --fps 5 -- -- a.mov b.mov
```

```bash
# Recorte de 10s a partir de 00:02:00, 3 fps, 1280 de largura
./video-to-image.sh --out out --start 00:02:00 --duration 10 --fps 3 --scale 1280:-1 -- -- clip.mp4
```

---

## ⚙️ Requisitos

- macOS (Apple Silicon/arm64).
- O script instala Homebrew e:
  - `ffmpeg` (obrigatório)
  - `oxipng` (para otimizar PNG — pode pular com `--no-opt`)
  - `webp` (se usar `--webp`)
  - `pillow` + `imagehash` (instala via `pip --user` quando usar `phash`)

---

## 🏎️ Performance tips

- Use `--no-opt` enquanto ajusta os filtros. Otimize depois em lote:
  ```bash
  find ./frames -name '*.png' -print0     | xargs -0 -n1 -P "$(sysctl -n hw.ncpu)" oxipng -o 3 --strip safe
  ```
- Prefira **720p** (`--scale -1:720`) e **fps** baixo se você quer volume menor.
- Quer ver progresso do `ffmpeg`?  
  `FFMPEG_LOGLEVEL=info ./video-to-image.sh ...`

---

## 🩹 Troubleshooting

- **Gera 0 frames**

  - `--unique`/`--scene` podem estar **agressivos**. Tente:
    - remover `--unique`, ou
    - `--scene 0.05~0.10 --scene-step 0.01`, ou
    - só `--fps 5 --scale -1:720` (sem dedupe na extração).
  - Rode com `--debug` ou `FFMPEG_LOGLEVEL=info` para ver o comando real.

- **Demora demais**

  - `oxipng --zopfli` é pesado. Use `--no-opt` ou otimize depois com `-o 3`.
  - Reduza `--fps` e/ou `--scale`.

- **Sobrescreveu algo?**
  - Com `--flat`, o script **prefixa automaticamente** pelo nome do vídeo (e incrementa `-2`, `-3` …).
  - Se quiser, force um `--prefix` seu.

---

## 📜 Licença

MIT — use sem cerimônia.

---

## 🤘 Assinatura

Se curtir, dá uma estrela no repo e manda ver.  
“Transformar vídeo em mosaico de tempo — do seu jeito, sem frescura.”
