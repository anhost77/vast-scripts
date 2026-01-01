#!/bin/bash
# =============================================================================
# HALLO3 - Génération d'une vidéo + UPSCALE (appelé pour chaque job)
# =============================================================================

IMAGE_URL="$1"
AUDIO_URL="$2"
WEBHOOK_RESULT="$3"
JOB_ID="$4"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}[STEP]${NC} $1"; }

echo "=========================================="
echo "  Hallo3 + Upscale - Job: $JOB_ID"
echo "=========================================="

if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    log_error "Usage: bash hallo3_run.sh <image_url> <audio_url> <webhook_url> [job_id]"
    exit 1
fi

log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
log_info "Webhook: $WEBHOOK_RESULT"
log_info "Job ID: $JOB_ID"

cd /workspace/hallo3

# =============================================================================
# ÉTAPE 1: NETTOYER ANCIEN JOB
# =============================================================================
log_step "Nettoyage ancien job..."
rm -rf /workspace/input/* /workspace/output/*
rm -f /workspace/hallo3/.cache/audio_preprocess/*
log_info "✅ Nettoyé"

# =============================================================================
# ÉTAPE 2: TÉLÉCHARGEMENT FICHIERS
# =============================================================================
log_step "Téléchargement fichiers..."

wget -q -O /workspace/input/source.png "$IMAGE_URL" || curl -sL "$IMAGE_URL" -o /workspace/input/source.png
wget -q -O /workspace/input/audio_raw "$AUDIO_URL" || curl -sL "$AUDIO_URL" -o /workspace/input/audio_raw

# Convertir audio en WAV 16kHz mono
ffmpeg -y -i /workspace/input/audio_raw -ar 16000 -ac 1 /workspace/input/audio.wav > /dev/null 2>&1 || \
    mv /workspace/input/audio_raw /workspace/input/audio.wav

# Vérifier taille fichiers
IMG_SIZE=$(stat -c%s /workspace/input/source.png 2>/dev/null || echo 0)
AUDIO_SIZE=$(stat -c%s /workspace/input/audio.wav 2>/dev/null || echo 0)

if [ "$IMG_SIZE" -lt 1000 ] || [ "$AUDIO_SIZE" -lt 1000 ]; then
    log_error "Fichiers trop petits (téléchargement échoué?)"
    log_error "Image: $IMG_SIZE bytes, Audio: $AUDIO_SIZE bytes"
    if [ -n "$WEBHOOK_RESULT" ]; then
        curl -s -X POST "$WEBHOOK_RESULT" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"error\",\"job_id\":\"$JOB_ID\",\"message\":\"Download failed - Image: $IMG_SIZE bytes, Audio: $AUDIO_SIZE bytes\"}"
    fi
    exit 1
fi

log_info "✅ Image: $(numfmt --to=iec $IMG_SIZE), Audio: $(numfmt --to=iec $AUDIO_SIZE)"

# =============================================================================
# ÉTAPE 3: PRÉPARER INPUT
# =============================================================================
log_step "Préparation inférence..."

cat > /workspace/input/input.txt << EOF
A person talking naturally@@/workspace/input/source.png@@/workspace/input/audio.wav
EOF

log_info "Input: $(cat /workspace/input/input.txt)"

# =============================================================================
# ÉTAPE 4: LANCER INFÉRENCE HALLO3
# =============================================================================
log_step "Lancement génération vidéo Hallo3..."

bash scripts/inference_long_batch.sh /workspace/input/input.txt /workspace/output 2>&1 | tee /workspace/hallo3_inference.log

# =============================================================================
# ÉTAPE 5: RÉCUPÉRER VIDÉO GÉNÉRÉE
# =============================================================================
log_step "Recherche vidéo générée..."

VIDEO_FILE=$(find /workspace/output -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -z "$VIDEO_FILE" ] || [ ! -f "$VIDEO_FILE" ]; then
    log_error "Aucune vidéo générée!"
    tail -20 /workspace/hallo3_inference.log
    
    if [ -n "$WEBHOOK_RESULT" ]; then
        ERROR_LOG=$(tail -10 /workspace/hallo3_inference.log | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 500)
        curl -s -X POST "$WEBHOOK_RESULT" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"error\",\"job_id\":\"$JOB_ID\",\"message\":\"No video generated\",\"log\":\"$ERROR_LOG\"}"
    fi
    exit 1
fi

log_info "✅ Vidéo Hallo3: $VIDEO_FILE"
log_info "Taille: $(numfmt --to=iec $(stat -c%s "$VIDEO_FILE"))"

# =============================================================================
# ÉTAPE 6: UPSCALE VIDÉO (ENVIRONNEMENT SÉPARÉ)
# =============================================================================
log_step "Upscale vidéo avec Real-ESRGAN..."

UPSCALE_ENV="/workspace/upscale_env"
UPSCALED_VIDEO="/workspace/output/video_upscaled.mp4"

# Créer environnement séparé si nécessaire
if [ ! -d "$UPSCALE_ENV" ]; then
    log_info "Création environnement upscale..."
    python -m venv "$UPSCALE_ENV"
    source "$UPSCALE_ENV/bin/activate"
    pip install --upgrade pip > /dev/null 2>&1
    pip install realesrgan opencv-python ffmpeg-python > /dev/null 2>&1
    deactivate
    log_info "✅ Environnement upscale créé"
else
    log_info "Environnement upscale existe déjà"
fi

# Activer et lancer upscale
source "$UPSCALE_ENV/bin/activate"

# Extraire frames, upscaler, réassembler
FRAMES_DIR="/workspace/output/frames"
FRAMES_UP_DIR="/workspace/output/frames_upscaled"
mkdir -p "$FRAMES_DIR" "$FRAMES_UP_DIR"

log_info "Extraction frames..."
ffmpeg -i "$VIDEO_FILE" -qscale:v 2 "$FRAMES_DIR/frame_%05d.png" -y > /dev/null 2>&1

FRAME_COUNT=$(ls -1 "$FRAMES_DIR" | wc -l)
log_info "Frames extraites: $FRAME_COUNT"

log_info "Upscale frames (x2)..."
python -c "
from realesrgan import RealESRGANer
from basicsr.archs.rrdbnet_arch import RRDBNet
import cv2
import glob
import os

model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=2)
upsampler = RealESRGANer(
    scale=2,
    model_path='https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth',
    model=model,
    half=True
)

frames = sorted(glob.glob('$FRAMES_DIR/*.png'))
total = len(frames)
for i, frame_path in enumerate(frames):
    img = cv2.imread(frame_path)
    output, _ = upsampler.enhance(img, outscale=2)
    out_path = '$FRAMES_UP_DIR/' + os.path.basename(frame_path)
    cv2.imwrite(out_path, output)
    if (i+1) % 50 == 0:
        print(f'  Upscaled {i+1}/{total} frames')
print(f'✅ Toutes les {total} frames upscalées')
"

# Récupérer FPS original
FPS=$(ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate "$VIDEO_FILE" | bc -l | xargs printf "%.2f")
log_info "FPS original: $FPS"

# Réassembler vidéo
log_info "Réassemblage vidéo upscalée..."
ffmpeg -framerate "$FPS" -i "$FRAMES_UP_DIR/frame_%05d.png" -i "$VIDEO_FILE" -map 0:v -map 1:a -c:v libx264 -preset medium -crf 18 -c:a copy "$UPSCALED_VIDEO" -y > /dev/null 2>&1

deactivate

# Nettoyage frames
rm -rf "$FRAMES_DIR" "$FRAMES_UP_DIR"

# Vérifier upscale
if [ -f "$UPSCALED_VIDEO" ]; then
    UPSCALED_SIZE=$(stat -c%s "$UPSCALED_VIDEO")
    log_info "✅ Vidéo upscalée: $UPSCALED_VIDEO"
    log_info "Taille: $(numfmt --to=iec $UPSCALED_SIZE)"
    
    # Afficher résolution
    RESOLUTION=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$UPSCALED_VIDEO")
    log_info "Résolution: $RESOLUTION"
    
    # Utiliser vidéo upscalée pour le webhook
    FINAL_VIDEO="$UPSCALED_VIDEO"
else
    log_error "Upscale échoué, utilisation vidéo originale"
    FINAL_VIDEO="$VIDEO_FILE"
fi

# =============================================================================
# ÉTAPE 7: ENVOI WEBHOOK
# =============================================================================
if [ -n "$WEBHOOK_RESULT" ]; then
    log_step "Envoi vidéo au webhook..."
    
    FINAL_SIZE=$(stat -c%s "$FINAL_VIDEO")
    
    curl -s -X POST "$WEBHOOK_RESULT" \
        -F "status=success" \
        -F "job_id=$JOB_ID" \
        -F "filename=$(basename $FINAL_VIDEO)" \
        -F "size=$FINAL_SIZE" \
        -F "upscaled=true" \
        -F "video=@$FINAL_VIDEO;type=video/mp4"
    
    log_info "✅ Webhook envoyé"
fi

log_info "🎉 Job $JOB_ID terminé!"
