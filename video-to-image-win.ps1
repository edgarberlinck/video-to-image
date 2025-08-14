param(
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Fps,
  [string]$Scale,
  [string]$Start,
  [string]$Duration,
  [switch]$Unique,
  [string]$Scene,
  [string]$SceneStep = "0.01",
  [string]$Dedupe,
  [switch]$Webp,
  [switch]$Flat,
  [string]$Prefix,
  [switch]$NoOpt,
  [switch]$Debug,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Inputs
)

if ($Debug) { $VerbosePreference="Continue" }
if (-not $Inputs -or -not $Out) { Write-Error "Uso: .\video-to-image.ps1 -Out <DIR> [opções] <video1> <video2> ..."; exit 1 }
New-Item -ItemType Directory -Path $Out -Force | Out-Null

function Have($cmd){ Get-Command $cmd -ErrorAction SilentlyContinue | ForEach-Object { $_ } }

# ---- Venv para pHash (Pillow + imagehash)
function Ensure-Venv {
  $global:Venv = Join-Path $env:LOCALAPPDATA "video_to_image\venv"
  if (-not (Test-Path "$Venv\Scripts\python.exe")) {
    $py = (Have py) ? "py -3" : ((Have python) ? "python" : "python3")
    if (-not $py) { Write-Error "Python 3 não encontrado. Instale e tente novamente."; exit 2 }
    New-Item -ItemType Directory -Path (Split-Path $Venv) -Force | Out-Null
    & $py -m venv $Venv
    & "$Venv\Scripts\pip.exe" -q install --upgrade pip wheel setuptools
    & "$Venv\Scripts\pip.exe" -q install pillow imagehash
  }
}

function Normalize-Prefix([string]$p){
  if ([string]::IsNullOrEmpty($p)) { return "" }
  if ($p.EndsWith("_")) { return $p } else { return "${p}_" }
}

function Make-Prefix([string]$name,[string]$out){
  $base = ($name -replace '[^a-zA-Z0-9._-]','_')
  $try = $base; $n=2
  while (Get-ChildItem -Path $out -Filter "${try}_*" -ErrorAction SilentlyContinue | Select-Object -First 1) { $try = "$base-$n"; $n++ }
  return "${try}_"
}

function Build-VF([string]$sceneT){
  $parts = @()
  if ($sceneT) { $parts += "select='gt(scene,$sceneT)'" }
  elseif ($Unique) { $parts += "mpdecimate=hi=768:lo=128:frac=0.33" }
  if ($Fps)   { $parts += "fps=$Fps" }
  if ($Scale) { $parts += "scale=$Scale:flags=lanczos" }
  return ($parts -join ",")
}

function Count-Frames([string]$dir,[string]$prefix,[string]$ext){
  (Get-ChildItem -Path $dir -Filter "${prefix}*.$ext" -ErrorAction SilentlyContinue).Count
}

function Optimize-PNG([string]$dir,[string]$prefix){
  if ($NoOpt) { return }
  if (-not (Have oxipng)) { Write-Verbose "oxipng ausente; pulando otimização"; return }
  Get-ChildItem -Path $dir -Filter "${prefix}*.png" -ErrorAction SilentlyContinue |
    ForEach-Object { & oxipng -o 3 --strip safe --quiet $_.FullName }
}

function Run-FF([string]$input,[string]$outdir,[string]$prefix,[string]$vf,[string]$ext){
  $outpat = Join-Path $outdir ("{0}%06d.{1}" -f $prefix,$ext)
  $args = @("-hide_banner","-loglevel", ($env:FFMPEG_LOGLEVEL ? $env:FFMPEG_LOGLEVEL : "error"), "-stats","-y","-hwaccel","d3d11va")
  if ($Start) { $args += @("-ss",$Start) }
  $args += @("-i",$input)
  if ($Duration) { $args += @("-t",$Duration) }
  if ($vf) { $args += @("-vf",$vf) }
  $args += @("-vsync","vfr","-f","image2")
  if ($ext -eq "png") { $args += @("-pix_fmt","rgb24","-compression_level","9","-pred","mixed",$outpat) }
  else { $args += @("-pix_fmt","rgb24","-lossless","1",$outpat) }
  Write-Verbose ("CMD: ffmpeg " + ($args -join " "))
  ffmpeg @args | Out-Null
}

function Dedupe-Exact([string]$dir){
  $seen = @{}
  Get-ChildItem -Path $dir -Include *.png,*.webp -Recurse:$false |
    ForEach-Object {
      $h = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash
      if ($seen.ContainsKey($h)) { Write-Output "removendo duplicado exato: $($_.Name)"; Remove-Item -Force $_.FullName }
      else { $seen[$h] = $_.FullName }
    }
}

function Py-Run([string]$code,[string[]]$args){
  Ensure-Venv
  $tmp = New-TemporaryFile; $pyfile = "$tmp.py"; Set-Content -Path $pyfile -Value $code -Encoding UTF8
  & "$Venv\Scripts\python.exe" $pyfile @args
  Remove-Item -Force $pyfile
}

$pyPhash = @'
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
'@

$pyDiverse = @'
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
'@

foreach ($input in $Inputs) {
  if (-not (Test-Path $input)) { Write-Warning "Não encontrado: $input"; continue }
  $name = [System.IO.Path]::GetFileNameWithoutExtension($input)

  # diretório
  if ($Flat) {
    $outdir = $Out
  } else {
    $outdir = Join-Path $Out $name
    $n=2; while (Test-Path $outdir) { $outdir = Join-Path $Out ("{0}-{1}" -f $name,$n); $n++ }
    New-Item -ItemType Directory -Path $outdir -Force | Out-Null
  }

  # prefixo por vídeo
  $prefixThis = if ($Prefix) { Normalize-Prefix $Prefix } elseif ($Flat) { Make-Prefix $name $Out } else { "" }
  $ext = $Webp.IsPresent ? "webp" : "png"
  $prefix = ($prefixThis + "frame_")

  Write-Host ">> Processando: $input"
  if ($Flat) { Write-Host ("   Prefixo: " + ($prefixThis ? $prefixThis : "<vazio>")) }

  $frames = 0
  if ($Scene -and $Scene.Contains("~")) {
    $a,$b = $Scene -split "~"; [double]$lo=[math]::Min([double]$a,[double]$b); [double]$hi=[math]::Max([double]$a,[double]$b)
    [double]$stp = [double]$SceneStep
    for ($t=$hi; $t -ge $lo-1e-9; $t-=$stp) {
      $vf = Build-VF $t
      Run-FF $input $outdir $prefix $vf $ext
      $frames = Count-Frames $outdir $prefix $ext
      if ($frames -gt 0) { break }
    }
  } else {
    $vf = Build-VF $Scene
    Run-FF $input $outdir $prefix $vf $ext
    $frames = Count-Frames $outdir $prefix $ext
  }

  if ($frames -eq 0) {
    Write-Host "   [fallback] sem dedupe/scene..."
    $vf = ""
    if ($Fps) { $vf = "fps=$Fps" }
    if ($Scale) { if ($vf) { $vf += "," }; $vf += "scale=$Scale:flags=lanczos" }
    Run-FF $input $outdir $prefix $vf $ext
    $frames = Count-Frames $outdir $prefix $ext
  }
  if ($frames -eq 0) {
    Write-Host "   [fallback] mínimo: fps=1, scale=-1:720..."
    Run-FF $input $outdir $prefix "fps=1,scale=-1:720:flags=lanczos" $ext
    $frames = Count-Frames $outdir $prefix $ext
  }
  if ($frames -eq 0) { Write-Warning "0 frames gerados."; continue }
  Write-Host "   Frames gerados: $frames"

  if ($ext -eq "png" -and -not $NoOpt) { Optimize-PNG $outdir $prefix }

  if ($Dedupe) {
    switch -Regex ($Dedupe) {
      '^exact$'        { Write-Host "   Dedupe exact..."; Dedupe-Exact $outdir }
      '^aggressive$'   { Write-Host "   Dedupe pHash 12..."; Py-Run $pyPhash @($outdir,"12") }
      '^diverse(?::(.+))?$' {
        $thr = if ($Matches[1]) { $Matches[1] } else { "12" }
        Write-Host "   Dedupe diverse (mindist=$thr)..."; Py-Run $pyDiverse @($outdir,$thr)
      }
      '^phash(?::(.+))?$' {
        $thr = if ($Matches[1]) { $Matches[1] } else { "5" }
        Write-Host "   Dedupe pHash (thr=$thr)..."; Py-Run $pyPhash @($outdir,$thr)
      }
      default { Write-Warning "   --dedupe desconhecido: $Dedupe" }
    }
  }

  $final = Count-Frames $outdir $prefix $ext
  Write-Host "   Concluído $name: $final frame(s) → $outdir"
}

Write-Host "Fim."
