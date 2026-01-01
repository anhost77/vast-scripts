#!/bin/bash
# =============================================================================
# HALLO3 - Script d'inférence (version légère)
# =============================================================================

set -e

IMAGE_URL="$1"
AUDIO_URL="$2"
WEBHOOK_URL="$3"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}[STEP]${NC} $1"; }

echo "=========================================="
echo "  Hallo3 - Inférence rapide"
echo "=========================================="

if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    log_error "Usage: bash hallo3_auto.sh <image_url> <audio_url> [webhook_url]"
    exit 1
fi

log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
log_info "Webhook: $WEBHOOK_URL"

cd /workspace/hallo3

# =============================================================================
# ÉTAPE 1: FIX DÉPENDANCES
# =============================================================================
log_step "Fix dépendances..."
pip install --quiet \
    numpy==1.26.4 \
    wandb==0.17.0 \
    albumentations \
    easydict \
    matplotlib \
    onnx \
    scikit-image \
    opencv-python-headless \
    prettytable \
    2>/dev/null || true
log_info "✅ Dépendances OK"

# =============================================================================
# ÉTAPE 2: TÉLÉCHARGEMENT FICHIERS INPUT
# =============================================================================
log_step "Téléchargement fichiers..."
mkdir -p /workspace/input /workspace/output

wget -q -O /workspace/input/source.png "$IMAGE_URL" || curl -sL "$IMAGE_URL" -o /workspace/input/source.png
wget -q -O /workspace/input/audio_raw "$AUDIO_URL" || curl -sL "$AUDIO_URL" -o /workspace/input/audio_raw
ffmpeg -y -i /workspace/input/audio_raw -ar 16000 -ac 1 /workspace/input/audio.wav > /dev/null 2>&1 || \
    mv /workspace/input/audio_raw /workspace/input/audio.wav

log_info "✅ Fichiers OK"

# =============================================================================
# ÉTAPE 3: PRÉPARER INPUT FILE
# =============================================================================
log_step "Préparation inférence..."

cat > /workspace/input/input.txt << EOF
A person talking naturally@@/workspace/input/source.png@@/workspace/input/audio.wav
EOF

log_info "Input: $(cat /workspace/input/input.txt)"

# =============================================================================
# ÉTAPE 4: LANCER INFÉRENCE
# =============================================================================
log_step "Lancement génération vidéo..."

bash scripts/inference_long_batch.sh /workspace/input/input.txt /workspace/output 2>&1 | tee /workspace/hallo3_inference.log

# =============================================================================
# ÉTAPE 5: RÉCUPÉRER RÉSULTAT ET ENVOYER
# =============================================================================
log_step "Recherche vidéo générée..."

VIDEO_FILE=$(find /workspace/output -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "$VIDEO_FILE" ] && [ -f "$VIDEO_FILE" ]; then
    log_info "✅ Vidéo: $VIDEO_FILE"
    VIDEO_SIZE=$(stat -c%s "$VIDEO_FILE")
    log_info "Taille: $(numfmt --to=iec $VIDEO_SIZE)"
    
    if [ -n "$WEBHOOK_URL" ]; then
        log_step "Envoi vidéo au webhook..."
        
        curl -s -X POST "$WEBHOOK_URL" \
            -F "status=success" \
            -F "filename=$(basename $VIDEO_FILE)" \
            -F "size=$VIDEO_SIZE" \
            -F "video=@$VIDEO_FILE;type=video/mp4"
        
        log_info "✅ Webhook envoyé"
    fi
else
    log_error "Aucune vidéo générée!"
    tail -20 /workspace/hallo3_inference.log
    
    if [ -n "$WEBHOOK_URL" ]; then
        ERROR_LOG=$(tail -10 /workspace/hallo3_inference.log | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 500)
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"error\",\"message\":\"No video generated\",\"log\":\"$ERROR_LOG\"}"
    fi
    exit 1
fi

log_info "🎉 Terminé!"
