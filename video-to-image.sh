#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

usage() {
  cat <<'EOF'
Uso:
  video_to_frames.sh --out <DIR> [opções] -- <video1> [video2 ...]
Exemplos:
  video_to_frames.sh --out ./frames -- -- input.mp4
  video_to_frames.sh --out ./frames --fps 5 --scale 1280:-1 --unique -- -- a.mp4 b.mov
  video_to_frames.sh --out ./frames --webp --dedupe phash:6 -- -- input.mp4
  video_to_frames.sh --out ./frames --flat -- -- a.mp4 b.mp4
  video_to_frames.sh --out ./frames --scene 0.05~0.10 --scene-step 0.01 -- -- clip.mp4
  video_to_frames.sh --out ./frames --no-opt --debug -- -- clip.mp4

Opções:
  --fps N            Limita a N fps (após dedupe, se habilitado)
  --scale WxH        Redimensiona (ex.: 1280:-1 ou -1:720), lanczos
  --start TIME       Começa em TIME (ex.: 00:00:05)
  --duration D       Duração (ex.: 10 ou 00:00:10)
  --unique           Remove quase idênticos na extração (mpdecimate)
  --scene T|A~B      Só mudanças de cena; aceita faixa A~B (tenta de B→A)
  --scene-step S     Passo quando usar faixa em --scene (padrão: 0.01)
  --dedupe MODE      Pós: "exact" | "phash[:N]" (N padrão 5)
  --webp             Salva em WebP lossless (menor que PNG)
  --flat             NÃO cria subpasta; usa prefixo automático por vídeo
  --prefix P         Prefixo manual (senão é gerado no --flat)
  --no-opt           Pula otimização de PNGs (mais rápido)
  --debug            Mostra comandos e logs do ffmpeg
  -h, --help         Ajuda

Notas:
- Sem --flat: saída em <DIR>/<basename>/frame_000001.ext
- Em --flat, prefixo automático baseado no nome do vídeo (com -2/-3 se preciso)
- Fallbacks automáticos se nenhum frame for gerado
EOF
}

# ---------- parse ----------
OUTDIR=""
FPS=""; SCALE=""; SS=""; DUR=""
UNIQUE="0"; SCENE=""; SCENE_STEP="0.01"; DEDUPE=""
USE_WEBP="0"
FLAT="0"; PREFIX=""
NO_OPT="0"; DEBUG="0"

args_before_inputs=1
INPUTS=()

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --out)      OUTDIR="${2:-}"; shift 2;;
    --fps)      FPS="${2:-}"; shift 2;;
    --scale)    SCALE="${2:-}"; shift 2;;
    --start)    SS="${2:-}"; shift 2;;
    --duration) DUR="${2:-}"; shift 2;;
    --unique)   UNIQUE="1"; shift;;
    --scene)    SCENE="${2:-}"; shift 2;;
    --scene-step) SCENE_STEP="${2:-}"; shift 2;;
    --dedupe)   DEDUPE="${2:-}"; shift 2;;
    --webp)     USE_WEBP="1"; shift;;
    --flat)     FLAT="1"; shift;;
    --prefix)   PREFIX="${2:-}"; shift 2;;
    --no-opt)   NO_OPT="1"; shift;;
    --debug)    DEBUG="1"; shift;;
    -h|--help)  usage; exit 0;;
    --)         shift; args_before_inputs=0; break;;
    *)          echo "Opção desconhecida ou fora de ordem: $1"; usage; exit 2;;
  esac
done
if (( args_before_inputs == 0 )); then
  while [[ $# -gt 0 ]]; do INPUTS+=("$1"); shift; done
fi

[[ -n "$OUTDIR" ]] || { echo "ERRO: falta --out <DIR>"; usage; exit 1; }
(( ${#INPUTS[@]} > 0 )) || { echo "ERRO: forneça ao menos um vídeo após --"; usage; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "ERRO: macOS apenas."; exit 4; }

mkdir -p "$OUTDIR"
[[ "$DEBUG" == "1" ]] && set -x

# ---------- Homebrew & ffmpeg/oxipng ----------
if ! command -v brew >/dev/null 2>&1; then
  echo "Instalando Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [[ -d "/opt/homebrew/bin" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
fi
command -v ffmpeg >/dev/null 2>&1 || brew install ffmpeg
command -v oxipng >/dev/null 2>&1 || brew install oxipng
if [[ "$USE_WEBP" == "1" ]]; then
  command -v cwebp >/dev/null 2>&1 || brew install webp
fi

# ---------- helpers ----------
make_unique_dir() {
  local base="$1" parent="$2" dir="$parent/$base" n=2
  while [[ -e "$dir" ]]; do dir="$parent/${base}-${n}"; ((n++)); done
  echo "$dir"
}

# evita loop: usa compgen -G para checar padrão
make_auto_prefix_for_flat() {
  local name="$1" out="$2"
  local base="${name//[^a-zA-Z0-9._-]/_}"
  local try="$base" n=2
  while compgen -G "$out/${try}_*" > /dev/null; do
    try="${base}-${n}"
    ((n++))
  done
  echo "${try}_"
}

# venv dedicado para o pHash (foge do PEP 668)
PHASH_VENV="${HOME}/.cache/video_to_frames/venv"
ensure_phash_env() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Instalando Python 3 via Homebrew..."
    brew install python || true
  fi
  if [[ ! -x "$PHASH_VENV/bin/python" ]]; then
    echo "Criando venv para pHash em: $PHASH_VENV"
    mkdir -p "$(dirname "$PHASH_VENV")"
    python3 -m venv "$PHASH_VENV"
    "$PHASH_VENV/bin/pip" --disable-pip-version-check -q install --upgrade pip wheel setuptools
    "$PHASH_VENV/bin/pip" --disable-pip-version-check -q install pillow imagehash
  fi
}

# monta -vf dado um scene_threshold opcional (vazio = sem select)
build_vf_with_scene() {
  local scene_t="${1:-}"
  local vf_parts=()
  if [[ -n "$scene_t" ]]; then
    vf_parts+=("select='gt(scene,${scene_t})'")
  elif [[ "$UNIQUE" == "1" ]]; then
    vf_parts+=("mpdecimate=hi=768:lo=128:frac=0.33")
  fi
  [[ -n "$FPS"   ]] && vf_parts+=("fps=${FPS}")
  [[ -n "$SCALE" ]] && vf_parts+=("scale=${SCALE}:flags=lanczos")
  if (( ${#vf_parts[@]} )); then (IFS=,; echo "${vf_parts[*]}"); else echo ""; fi
}

count_frames() {
  local dir="$1" prefix="$2" ext="$3"
  ls -1 "$dir"/${prefix}*.${ext} 2>/dev/null | wc -l | tr -d ' '
}

# otimização rápida por padrão (evita travas)
optimize_pngs_parallel() {
  local dir="$1" prefix="$2"
  local cores; cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  find "$dir" -type f -name "${prefix}*.png" -print0 \
    | xargs -0 -n1 -P "$cores" oxipng -o 3 --strip safe --quiet || true
}

dedupe_exact() {
  local dir="$1"
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  find "$dir" -type f \( -name '*.png' -o -name '*.webp' \) -print0 \
    | xargs -0 -I{} sh -c 'shasum -a 256 "{}"' \
    | sort > "$tmp"
  awk '{
    hash=$1; file=$2;
    if (seen[hash]++) { printf("removendo duplicado exato: %s\n", file); cmd="rm -f \"" file "\""; system(cmd); }
  }' "$tmp"
}

# usa o venv dedicado (Pillow + imagehash)
dedupe_phash() {
  local dir="$1"; local thresh="${2:-5}"
  ensure_phash_env
  "$PHASH_VENV/bin/python" - "$dir" "$thresh" <<'PY'
import sys, os, glob
from PIL import Image
import imagehash

folder = sys.argv[1]
threshold = int(sys.argv[2]) if len(sys.argv) > 2 else 5

files = sorted(glob.glob(os.path.join(folder, "*.png")) + glob.glob(os.path.join(folder, "*.webp")))
seen = []

def get_hash(path):
    try:
        with Image.open(path) as im:
            im = im.convert("RGB")
            return imagehash.phash(im)
    except Exception:
        return None

for f in files:
    hf = get_hash(f)
    if hf is None:
        continue
    dup = False
    for (g, hg) in seen:
        if hf - hg <= threshold:
            print(f"removendo quase-duplicado (dist={hf-hg}): {f} ~ {g}")
            try:
                os.remove(f)
            except FileNotFoundError:
                pass
            dup = True
            break
    if not dup:
        seen.append((f, hf))
PY
}

run_ffmpeg_once() {
  local input="$1" outdir="$2" prefix="$3" vf="$4" ext="$5" ss="$6" dur="$7"
  local loglevel="${FFMPEG_LOGLEVEL:-error}"
  local outpat="$outdir/${prefix}%06d.${ext}"

  local cmd=(ffmpeg -hide_banner -loglevel "$loglevel" -stats -y)
  cmd+=(-hwaccel videotoolbox)
  [[ -n "$ss"  ]] && cmd+=(-ss "$ss")
  cmd+=(-i "$input")
  [[ -n "$dur" ]] && cmd+=(-t "$dur")
  [[ -n "$vf"  ]] && cmd+=(-vf "$vf")
  cmd+=(-vsync vfr -f image2)
  if [[ "$ext" == "png" ]]; then
    cmd+=(-pix_fmt rgb24 -compression_level 9 -pred mixed "$outpat")
  else
    cmd+=(-pix_fmt rgb24 -lossless 1 "$outpat")
  fi

  echo "   CMD: ${cmd[*]}"
  "${cmd[@]}" || true
}

# thresholds B..A (desc) quando --scene=A~B
scene_candidates_desc() {
  local range="$1" step="$2"
  /usr/bin/env python3 - "$range" "$step" <<'PY'
import sys
lo,hi = sys.argv[1].split('~')
lo=float(lo); hi=float(hi); step=float(sys.argv[2])
if hi < lo: lo,hi = hi,lo
vals=[]
x=hi
from decimal import Decimal, getcontext
getcontext().prec=6
dlo=Decimal(str(lo)); dhi=Decimal(str(hi)); dstep=Decimal(str(step))
x=dhi
while x >= dlo - Decimal("1e-9"):
    vals.append(str(float(x)))
    x = x - dstep
print(" ".join(vals))
PY
}

# ---------- processamento ----------
for INPUT in "${INPUTS[@]}"; do
  [[ -f "$INPUT" ]] || { echo "Aviso: não encontrado, pulando: $INPUT"; continue; }

  base="$(basename "$INPUT")"
  name="${base%.*}"

  # Decide diretório/prefixo
  if [[ "$FLAT" == "1" ]]; then
    outdir_video="$OUTDIR"
    if [[ -z "$PREFIX" ]]; then PREFIX="$(make_auto_prefix_for_flat "$name" "$OUTDIR")"; fi
  else
    outdir_video="$(make_unique_dir "$name" "$OUTDIR")"
    mkdir -p "$outdir_video"
  fi

  ext="png"; [[ "$USE_WEBP" == "1" ]] && ext="webp"
  prefix="${PREFIX}frame_"

  echo ">> Processando: $INPUT"
  echo "   Saída: $outdir_video (formato: $ext)"
  [[ -n "$SS"  ]] && echo "   -ss $SS"
  [[ -n "$DUR" ]] && echo "   -t  $DUR"
  [[ "$FLAT" == "1" ]] && echo "   Prefixo: ${PREFIX}"

  frames_count=0

  # 1) --scene faixa: tenta de B→A
  if [[ -n "$SCENE" && "$SCENE" == *~* ]]; then
    echo "   Tentando thresholds de cena (desc): $SCENE passo $SCENE_STEP"
    read -r -a SCENE_LIST <<<"$(scene_candidates_desc "$SCENE" "$SCENE_STEP")"
    for scene_t in "${SCENE_LIST[@]}"; do
      vf_try="$(build_vf_with_scene "$scene_t")"
      echo "   -vf scene=${scene_t}"
      run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_try" "$ext" "$SS" "$DUR"
      frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
      (( frames_count > 0 )) && break
    done
  else
    vf_primary="$(build_vf_with_scene "${SCENE}")"
    [[ -n "$vf_primary" ]] && echo "   -vf primário: \"$vf_primary\""
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_primary" "$ext" "$SS" "$DUR"
    frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi

  # 2) Fallback sem dedupe/scene
  if (( frames_count == 0 )); then
    echo "   [fallback] 0 frames; tentando sem dedupe/scene..."
    vf_no_ded=""
    [[ -n "$FPS"   ]] && vf_no_ded+="fps=${FPS}"
    if [[ -n "$SCALE" ]]; then
      [[ -n "$vf_no_ded" ]] && vf_no_ded+=","
      vf_no_ded+="scale=${SCALE}:flags=lanczos"
    fi
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_no_ded" "$ext" "$SS" "$DUR"
    frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi

  # 3) Fallback mínimo
  if (( frames_count == 0 )); then
    echo "   [fallback] Ainda 0; fps=1, scale=-1:720..."
    vf_min="fps=1,scale=-1:720:flags=lanczos"
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_min" "$ext" "$SS" "$DUR"
    frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi

  if (( frames_count == 0 )); then
    echo "   Falhou: 0 frames gerados. Use --debug ou FFMPEG_LOGLEVEL=info para diagnosticar."
    continue
  fi

  echo "   Frames gerados: $frames_count"

  # Otimização PNG (rápida) — pule com --no-opt
  if [[ "$ext" == "png" && "$NO_OPT" != "1" ]]; then
    echo "   Otimizando PNGs em paralelo..."
    optimize_pngs_parallel "$outdir_video" "$prefix"
  fi

  # Dedupe pós-processo
  if [[ -n "$DEDUPE" ]]; then
    case "$DEDUPE" in
      exact) echo "   Removendo duplicados exatos..."; dedupe_exact "$outdir_video" ;;
      phash|phash:*)
        thr="5"; [[ "$DEDUPE" == phash:* ]] && thr="${DEDUPE#phash:}"
        echo "   Removendo quase-duplicados (pHash, threshold=${thr})..."
        dedupe_phash "$outdir_video" "$thr"
        ;;
      *) echo "   Aviso: --dedupe desconhecido: $DEDUPE (ignorando)";;
    esac
  fi

  final_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  echo "   Concluído ${name}: ${final_count} frame(s) em $outdir_video"
done

echo "Fim."
