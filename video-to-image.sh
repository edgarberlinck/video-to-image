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
  video_to_frames.sh --out ./frames --no-opt --debug -- -- clip.mp4

Opções:
  --fps N            Limita a N fps (após dedupe, se habilitado)
  --scale WxH        Redimensiona (ex.: 1280:-1 ou -1:720), lanczos
  --start TIME       Começa em TIME (ex.: 00:00:05)
  --duration D       Duração (ex.: 10 ou 00:00:10)
  --unique           Remove frames quase idênticos na extração (mpdecimate)
  --scene T          Mantém só mudanças de cena (select='gt(scene,T)') ex.: 0.08
  --dedupe MODE      Pós-processo: "exact" | "phash[:N]" (N padrão 5)
  --webp             Salva em WebP lossless (menor que PNG). Requer 'webp'
  --flat             NÃO cria subpasta por vídeo (tudo em <DIR>, c/ prefixo automático por vídeo)
  --prefix P         Prefixo manual (senão é gerado do nome do vídeo em --flat)
  --no-opt           Pula otimização de PNGs com oxipng (mais rápido)
  --debug            Mostra comandos e logs mais verbosos do ffmpeg
  -h, --help         Ajuda

Notas:
- Sem --flat: saída por vídeo vai para <DIR>/<basename>/frame_000001.ext
- Em --flat, se você não passar --prefix, o script usa o basename do vídeo,
  adicionando -2/-3 se necessário para evitar colisão.
- Fallbacks automáticos se nenhum frame for gerado.
EOF
}

# ---------- parse ----------
OUTDIR=""
FPS=""; SCALE=""; SS=""; DUR=""
UNIQUE="0"; SCENE=""; DEDUPE=""
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

# ---------- Homebrew & deps ----------
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

# corrigido: evita loop infinito com ls; usa compgen -G
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

build_vf() {
  local vf_parts=()
  if [[ -n "$SCENE" ]]; then
    vf_parts+=("select='gt(scene,${SCENE})'")
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

optimize_pngs_parallel() {
  local dir="$1" prefix="$2"
  local cores; cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  find "$dir" -type f -name "${prefix}*.png" -print0 \
    | xargs -0 -n1 -P "$cores" oxipng -o max --strip all --zopfli --quiet || true
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

dedupe_phash() {
  local dir="$1"; local thresh="${2:-5}"
  /usr/bin/env python3 - "$dir" "$thresh" <<'PY'
import sys, os, glob
from PIL import Image
try:
    import imagehash
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "pillow", "imagehash"])
    import imagehash
folder = sys.argv[1]
threshold = int(sys.argv[2]) if len(sys.argv) > 2 else 5
files = sorted(glob.glob(os.path.join(folder, "*.png")) + glob.glob(os.path.join(folder, "*.webp")))
seen=[]
def h(path):
    try:
        with Image.open(path) as im:
            im = im.convert("RGB")
            return imagehash.phash(im)
    except Exception:
        return None
for f in files:
    hf = h(f)
    if hf is None: continue
    dup=False
    for (g,hg) in seen:
        if hf - hg <= threshold:
            print(f"removendo quase-duplicado (dist={hf-hg}): {f} ~ {g}")
            try: os.remove(f)
            except FileNotFoundError: pass
            dup=True
            break
    if not dup:
        seen.append((f,hf))
PY
}

run_ffmpeg_once() {
  local input="$1" outdir="$2" prefix="$3" vf="$4" ext="$5" ss="$6" dur="$7"
  local loglevel="${FFMPEG_LOGLEVEL:-error}"  # export FFMPEG_LOGLEVEL=info se quiser
  local outpat="$outdir/${prefix}%06d.${ext}"

  local cmd=(ffmpeg -hide_banner -loglevel "$loglevel" -stats -y)
  # aceleração por hardware (melhora velocidade em M1)
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
  vf_primary="$(build_vf)"

  echo ">> Processando: $INPUT"
  echo "   Saída: $outdir_video (formato: $ext)"
  [[ -n "$vf_primary" ]] && echo "   -vf primário: \"$vf_primary\""
  [[ -n "$SS"  ]] && echo "   -ss $SS"
  [[ -n "$DUR" ]] && echo "   -t  $DUR"
  [[ "$FLAT" == "1" ]] && echo "   Prefixo: ${PREFIX}"

  # 1) Rodada principal (com filtros escolhidos)
  run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_primary" "$ext" "$SS" "$DUR"
  c1=$(count_frames "$outdir_video" "$prefix" "$ext")

  if (( c1 == 0 )) && { [[ "$UNIQUE" == "1" ]] || [[ -n "$SCENE" ]]; }; then
    echo "   [fallback] 0 frames com dedupe/scene; tentando sem dedupe/scene..."
    # 2) Sem dedupe/scene, mantendo fps/scale do usuário
    vf_no_ded=""
    [[ -n "$FPS"   ]] && vf_no_ded+="fps=${FPS}"
    if [[ -n "$SCALE" ]]; then
      [[ -n "$vf_no_ded" ]] && vf_no_ded+=","
      vf_no_ded+="scale=${SCALE}:flags=lanczos"
    fi
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_no_ded" "$ext" "$SS" "$DUR"
    c1=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi

  if (( c1 == 0 )); then
    echo "   [fallback] Ainda 0; tentando mínimo (fps=1, scale=-1:720)..."
    vf_min="fps=1,scale=-1:720:flags=lanczos"
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_min" "$ext" "$SS" "$DUR"
    c1=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi

  if (( c1 == 0 )); then
    echo "   Falhou: 0 frames gerados. Rode com --debug ou FFMPEG_LOGLEVEL=info para diagnosticar."
    continue
  fi

  echo "   Frames gerados: $c1"

  # Otimização PNG (opcional)
  if [[ "$ext" == "png" && "$NO_OPT" != "1" ]]; then
    echo "   Otimizando PNGs em paralelo..."
    optimize_pngs_parallel "$outdir_video" "$prefix"
  fi

  # Dedupe pós-processamento, se solicitado
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
