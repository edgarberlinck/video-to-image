#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

usage() {
  cat <<'EOF'
Uso:
  video-to-image.sh --out <DIR> [opções] -- <video1> [video2 ...]
Opções:
  --fps N            Limita a N fps
  --scale WxH        Ex.: 1280:-1 ou -1:720 (lanczos)
  --start TIME       Ex.: 00:00:05
  --duration D       Ex.: 10 ou 00:00:10
  --unique           Dedupe na extração (mpdecimate)
  --scene T|A~B      Mudanças de cena; faixa A~B tenta B→A
  --scene-step S     Passo p/ faixa (padrão 0.01)
  --dedupe MODE      Pós: exact | phash[:N] | aggressive | diverse[:N]
  --webp             Saída WebP lossless (senão PNG)
  --flat             Não cria subpastas; prefixo automático por vídeo
  --prefix P         Prefixo manual (aplicado por vídeo; no flat garante _)
  --no-opt           Pula otimização PNG
  --debug            Logs verbosos
  -h, --help         Ajuda
EOF
}

# -------- parse --------
OUTDIR=""
FPS=""; SCALE=""; SS=""; DUR=""
UNIQUE="0"; SCENE=""; SCENE_STEP="0.01"; DEDUPE=""
USE_WEBP="0"; FLAT="0"; USER_PREFIX=""; NO_OPT="0"; DEBUG="0"
args_before_inputs=1; INPUTS=()

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --out) OUTDIR="${2:-}"; shift 2;;
    --fps) FPS="${2:-}"; shift 2;;
    --scale) SCALE="${2:-}"; shift 2;;
    --start) SS="${2:-}"; shift 2;;
    --duration) DUR="${2:-}"; shift 2;;
    --unique) UNIQUE="1"; shift;;
    --scene) SCENE="${2:-}"; shift 2;;
    --scene-step) SCENE_STEP="${2:-}"; shift 2;;
    --dedupe) DEDUPE="${2:-}"; shift 2;;
    --webp) USE_WEBP="1"; shift;;
    --flat) FLAT="1"; shift;;
    --prefix) USER_PREFIX="${2:-}"; shift 2;;
    --no-opt) NO_OPT="1"; shift;;
    --debug) DEBUG="1"; shift;;
    -h|--help) usage; exit 0;;
    --) shift; args_before_inputs=0; break;;
    *) echo "Opção desconhecida: $1"; usage; exit 2;;
  esac
done
if (( args_before_inputs == 0 )); then while [[ $# -gt 0 ]]; do INPUTS+=("$1"); shift; done; fi
[[ -n "$OUTDIR" ]] || { echo "ERRO: falta --out <DIR>"; exit 1; }
(( ${#INPUTS[@]} > 0 )) || { echo "ERRO: forneça ao menos um vídeo após --"; exit 1; }
mkdir -p "$OUTDIR"
[[ "$DEBUG" == "1" ]] && set -x

# -------- deps (best-effort) --------
have() { command -v "$1" >/dev/null 2>&1; }
pm=""
for p in apt-get dnf pacman zypper; do have "$p" && pm="$p" && break; done
install_try() {
  case "$pm" in
    apt-get) sudo apt-get update -y && sudo apt-get install -y "$@" || true ;;
    dnf)     sudo dnf install -y "$@" || true ;;
    pacman)  sudo pacman -Sy --noconfirm "$@" || true ;;
    zypper)  sudo zypper install -y "$@" || true ;;
  esac
}
have ffmpeg || install_try ffmpeg
have oxipng || { install_try oxipng; have oxipng || echo "Aviso: oxipng não encontrado, usando --no-opt."; }
have cwebp  || install_try libwebp-tools
have python3 || install_try python3
python3 -m venv --help >/dev/null 2>&1 || install_try python3-venv python3-pip

# -------- helpers --------
make_unique_dir() { local base="$1" parent="$2" dir="$parent/$base" n=2; while [[ -e "$dir" ]]; do dir="$parent/${base}-${n}"; ((n++)); done; echo "$dir"; }
make_auto_prefix_for_flat() {
  local name="$1" out="$2" base="${name//[^a-zA-Z0-9._-]/_}" try="$base" n=2
  while compgen -G "$out/${try}_*" > /dev/null; do try="${base}-${n}"; ((n++)); done
  echo "${try}_"
}
normalize_user_prefix() { local p="$1"; [[ -z "$p" ]] && { echo ""; return; }; [[ "${p: -1}" == "_" ]] && echo "$p" || echo "${p}_"; }
resolve_prefix_for_video() {
  local vname="$1"
  if [[ -n "$USER_PREFIX" ]]; then normalize_user_prefix "$USER_PREFIX"
  elif [[ "$FLAT" == "1" ]]; then make_auto_prefix_for_flat "$vname" "$OUTDIR"
  else echo ""; fi
}

PHASH_VENV="${HOME}/.cache/video_to_image/venv"
ensure_phash_env() {
  if [[ ! -x "$PHASH_VENV/bin/python" ]]; then
    mkdir -p "$(dirname "$PHASH_VENV")"
    python3 -m venv "$PHASH_VENV"
    "$PHASH_VENV/bin/pip" -q install --upgrade pip wheel setuptools
    "$PHASH_VENV/bin/pip" -q install pillow imagehash
  fi
}

build_vf_with_scene() {
  local scene_t="${1:-}" ; local vf_parts=()
  if [[ -n "$scene_t" ]]; then vf_parts+=("select='gt(scene,${scene_t})'")
  elif [[ "$UNIQUE" == "1" ]]; then vf_parts+=("mpdecimate=hi=768:lo=128:frac=0.33"); fi
  [[ -n "$FPS"   ]] && vf_parts+=("fps=${FPS}")
  [[ -n "$SCALE" ]] && vf_parts+=("scale=${SCALE}:flags=lanczos")
  if (( ${#vf_parts[@]} )); then (IFS=,; echo "${vf_parts[*]}"); else echo ""; fi
}

count_frames() { local dir="$1" prefix="$2" ext="$3"; ls -1 "$dir"/${prefix}*.${ext} 2>/dev/null | wc -l | tr -d ' '; }
cores() { command -v nproc >/dev/null && nproc || getconf _NPROCESSORS_ONLN || echo 4; }
optimize_pngs_parallel() {
  local dir="$1" prefix="$2"
  [[ "${NO_OPT}" == "1" || ! "$(command -v oxipng)" ]] && return 0
  find "$dir" -type f -name "${prefix}*.png" -print0 | xargs -0 -n1 -P "$(cores)" oxipng -o 3 --strip safe --quiet || true
}

dedupe_exact() {
  local dir="$1" tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  find "$dir" -type f \( -name '*.png' -o -name '*.webp' \) -print0 | xargs -0 -I{} sh -c 'sha256sum "{}"' | sort > "$tmp"
  awk '{
    hash=$1; file=$2;
    if (seen[hash]++) { printf("removendo duplicado exato: %s\n", file); system("rm -f \"" file "\""); }
  }' "$tmp"
}

dedupe_phash() {
  local dir="$1" thr="${2:-5}"
  ensure_phash_env
  "$PHASH_VENV/bin/python" - "$dir" "$thr" <<'PY'
import sys, os, glob
from PIL import Image
import imagehash
folder=sys.argv[1]; thr=int(sys.argv[2]) if len(sys.argv)>2 else 5
files=sorted(glob.glob(os.path.join(folder,"*.png"))+glob.glob(os.path.join(folder,"*.webp")))
seen=[]
def h(p):
  try:
    with Image.open(p) as im:
      return imagehash.phash(im.convert("RGB"))
  except: return None
for f in files:
  hf=h(f)
  if hf is None: continue
  dup=False
  for (g,hg) in seen:
    if hf-hg<=thr:
      print(f"removendo quase-duplicado (dist={hf-hg}): {f} ~ {g}")
      try: os.remove(f)
      except: pass
      dup=True; break
  if not dup: seen.append((f,hf))
PY
}

dedupe_diverse() {
  local dir="$1" mind="${2:-12}"
  ensure_phash_env
  "$PHASH_VENV/bin/python" - "$dir" "$mind" <<'PY'
import sys, os, glob
from PIL import Image
import imagehash
folder=sys.argv[1]; mind=int(sys.argv[2]) if len(sys.argv)>2 else 12
files=sorted(glob.glob(os.path.join(folder,"*.png"))+glob.glob(os.path.join(folder,"*.webp")))
kept=[]; removed=0
def h(p):
  try:
    with Image.open(p) as im:
      return imagehash.phash(im.convert("RGB"))
  except: return None
for f in files:
  hf=h(f)
  if hf is None: continue
  if not kept: kept.append((f,hf)); continue
  dmin=min(hf-kh for _,kh in kept)
  if dmin>=mind: kept.append((f,hf))
  else:
    print(f"removendo por baixa diversidade (minDist={dmin} < {mind}): {f}")
    try: os.remove(f); removed+=1
    except: pass
print(f"[diverse] mantidos={len(kept)} removidos={removed} mindist={mind}")
PY
}

run_ffmpeg_once() {
  local input="$1" outdir="$2" prefix="$3" vf="$4" ext="$5" ss="$6" dur="$7"
  local loglevel="${FFMPEG_LOGLEVEL:-error}"
  local outpat="$outdir/${prefix}%06d.${ext}"
  local cmd=(ffmpeg -hide_banner -loglevel "$loglevel" -stats -y)
  cmd+=(-hwaccel auto)
  [[ -n "$ss"  ]] && cmd+=(-ss "$ss")
  cmd+=(-i "$input")
  [[ -n "$dur" ]] && cmd+=(-t "$dur")
  [[ -n "$vf"  ]] && cmd+=(-vf "$vf")
  cmd+=(-vsync vfr -f image2)
  if [[ "$ext" == "png" ]]; then cmd+=(-pix_fmt rgb24 -compression_level 9 -pred mixed "$outpat")
  else cmd+=(-pix_fmt rgb24 -lossless 1 "$outpat"); fi
  echo "   CMD: ${cmd[*]}"; "${cmd[@]}" || true
}

scene_candidates_desc() {
  local range="$1" step="$2"
  /usr/bin/env python3 - "$range" "$step" <<'PY'
import sys
lo,hi=sys.argv[1].split('~'); lo=float(lo); hi=float(hi); step=float(sys.argv[2])
if hi<lo: lo,hi=hi,lo
vals=[]; x=hi
from decimal import Decimal, getcontext
getcontext().prec=6
dlo=Decimal(str(lo)); dhi=Decimal(str(hi)); dstep=Decimal(str(step))
x=dhi
while x>=dlo-Decimal("1e-9"):
  vals.append(str(float(x))); x=x-dstep
print(" ".join(vals))
PY
}

# -------- processamento --------
for INPUT in "${INPUTS[@]}"; do
  [[ -f "$INPUT" ]] || { echo "Aviso: não encontrado, pulando: $INPUT"; continue; }
  base="$(basename "$INPUT")"; name="${base%.*}"

  if [[ "$FLAT" == "1" ]]; then
    outdir_video="$OUTDIR"
  else
    outdir_video="$(make_unique_dir "$name" "$OUTDIR")"; mkdir -p "$outdir_video"
  fi

  PREFIX_THIS="$(resolve_prefix_for_video "$name")"
  ext="png"; [[ "$USE_WEBP" == "1" ]] && ext="webp"
  prefix="${PREFIX_THIS}frame_"

  echo ">> Processando: $INPUT"
  [[ "$FLAT" == "1" ]] && echo "   Prefixo: ${PREFIX_THIS:-<vazio>}"

  frames_count=0
  if [[ -n "$SCENE" && "$SCENE" == *~* ]]; then
    echo "   Tentando thresholds de cena: $SCENE passo $SCENE_STEP"
    read -r -a SCENE_LIST <<<"$(scene_candidates_desc "$SCENE" "$SCENE_STEP")"
    for scene_t in "${SCENE_LIST[@]}"; do
      vf_try="$(build_vf_with_scene "$scene_t")"; echo "   -vf scene=${scene_t}"
      run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_try" "$ext "$SS" "$DUR"
      frames_count=$(count_frames "$outdir_video" "$prefix" "$ext"); (( frames_count>0 )) && break
    done
  else
    vf_primary="$(build_vf_with_scene "${SCENE}")"; [[ -n "$vf_primary" ]] && echo "   -vf primário: \"$vf_primary\""
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_primary" "$ext" "$SS" "$DUR"
    frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi

  if (( frames_count == 0 )); then
    echo "   [fallback] sem dedupe/scene..."
    vf_no_ded=""; [[ -n "$FPS" ]] && vf_no_ded+="fps=${FPS}"
    if [[ -n "$SCALE" ]]; then [[ -n "$vf_no_ded" ]] && vf_no_ded+=","; vf_no_ded+="scale=${SCALE}:flags=lanczos"; fi
    run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_no_ded" "$ext" "$SS" "$DUR"
    frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi
  if (( frames_count == 0 )); then
    echo "   [fallback] mínimo: fps=1, scale=-1:720..."
    vf_min="fps=1,scale=-1:720:flags=lanczos"; run_ffmpeg_once "$INPUT" "$outdir_video" "$prefix" "$vf_min" "$ext" "$SS" "$DUR"
    frames_count=$(count_frames "$outdir_video" "$prefix" "$ext")
  fi
  (( frames_count == 0 )) && { echo "   Falhou: 0 frames."; continue; }
  echo "   Frames gerados: $frames_count"

  [[ "$ext" == "png" && "$NO_OPT" != "1" ]] && optimize_pngs_parallel "$outdir_video" "$prefix"

  if [[ -n "$DEDUPE" ]]; then
    case "$DEDUPE" in
      exact) echo "   Dedupe exact..."; dedupe_exact "$outdir_video" ;;
      aggressive) echo "   Dedupe pHash 12..."; dedupe_phash "$outdir_video" "12" ;;
      diverse|diverse:*) thr="12"; [[ "$DEDUPE" == diverse:* ]] && thr="${DEDUPE#diverse:}"
        echo "   Dedupe diverse (mindist=${thr})..."; dedupe_diverse "$outdir_video" "$thr" ;;
      phash|phash:*) thr="5"; [[ "$DEDUPE" == phash:* ]] && thr="${DEDUPE#phash:}"
        echo "   Dedupe pHash (thr=${thr})..."; dedupe_phash "$outdir_video" "$thr" ;;
      *) echo "   --dedupe desconhecido: $DEDUPE";;
    esac
  fi

  final_count=$(count_frames "$outdir_video" "$prefix" "$ext")
