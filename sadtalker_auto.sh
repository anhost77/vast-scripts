#!/bin/bash
# =============================================================================
# SADTALKER ONLY - Vast.ai
# Génère une vidéo talking head (sans LatentSync)
# Usage: bash sadtalker_only.sh <image_url> <audio_url> <webhook_url>
# =============================================================================

set -e

# Couleurs pour les logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# =============================================================================
# CONFIGURATION
# =============================================================================
WORK_DIR="/workspace"
OUTPUT_DIR="/workspace/output"
IMAGE_URL="${1:-}"
AUDIO_URL="${2:-}"
WEBHOOK_URL="${3:-}"

# =============================================================================
# VÉRIFICATION DES ARGUMENTS
# =============================================================================
if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo ""
    echo "=========================================="
    echo "  SadTalker ONLY - Vast.ai"
    echo "=========================================="
    echo ""
    log_error "Arguments manquants !"
    echo ""
    echo "Usage: bash sadtalker_only.sh <image_url> <audio_url> [webhook_url]"
    echo ""
    exit 1
fi

echo ""
echo "=========================================="
echo "  SadTalker ONLY - Vast.ai"
echo "=========================================="
echo ""
log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
[ -n "$WEBHOOK_URL" ] && log_info "Webhook: $WEBHOOK_URL"
echo ""

# =============================================================================
# INSTALLATION DÉPENDANCES SYSTÈME
# =============================================================================
log_step "Installation des dépendances système..."
apt-get update -qq
apt-get install -y -qq wget curl git ffmpeg libgl1-mesa-glx libglib2.0-0 unzip > /dev/null 2>&1
log_info "Dépendances système installées"

# =============================================================================
# TÉLÉCHARGEMENT DES FICHIERS INPUT
# =============================================================================
log_step "Téléchargement des fichiers d'entrée..."

mkdir -p "$WORK_DIR/input"
mkdir -p "$OUTPUT_DIR"

# Détection extension image
IMAGE_EXT="${IMAGE_URL##*.}"
IMAGE_EXT="${IMAGE_EXT%%\?*}"
[ -z "$IMAGE_EXT" ] || [ ${#IMAGE_EXT} -gt 4 ] && IMAGE_EXT="png"

# Détection extension audio
AUDIO_EXT="${AUDIO_URL##*.}"
AUDIO_EXT="${AUDIO_EXT%%\?*}"
[ -z "$AUDIO_EXT" ] || [ ${#AUDIO_EXT} -gt 4 ] && AUDIO_EXT="wav"

log_info "Téléchargement de l'image..."
wget -q --show-progress -O "$WORK_DIR/input/avatar.$IMAGE_EXT" "$IMAGE_URL" || {
    log_error "Impossible de télécharger l'image"
    exit 1
}

log_info "Téléchargement de l'audio..."
wget -q --show-progress -O "$WORK_DIR/input/audio.$AUDIO_EXT" "$AUDIO_URL" || {
    log_error "Impossible de télécharger l'audio"
    exit 1
}

# Conversion audio en WAV 16kHz mono
log_info "Conversion audio en WAV 16kHz mono..."
if [ "$AUDIO_EXT" != "wav" ]; then
    ffmpeg -y -i "$WORK_DIR/input/audio.$AUDIO_EXT" -ar 16000 -ac 1 "$WORK_DIR/input/audio.wav" -loglevel quiet || {
        log_warn "Conversion échouée, copie simple..."
        cp "$WORK_DIR/input/audio.$AUDIO_EXT" "$WORK_DIR/input/audio.wav"
    }
else
    ffmpeg -y -i "$WORK_DIR/input/audio.wav" -ar 16000 -ac 1 "$WORK_DIR/input/audio_converted.wav" -loglevel quiet && \
    mv "$WORK_DIR/input/audio_converted.wav" "$WORK_DIR/input/audio.wav" || true
fi

log_info "Fichiers prêts"

# =============================================================================
# SADTALKER - Animation du visage
# =============================================================================
echo ""
log_step "=========================================="
log_step "SadTalker - Animation du visage"
log_step "=========================================="
echo ""

SADTALKER_DIR="$WORK_DIR/sadtalker"

if [ ! -d "$SADTALKER_DIR" ]; then
    log_info "Clonage de SadTalker..."
    git clone --depth 1 https://github.com/OpenTalker/SadTalker.git "$SADTALKER_DIR"
fi

cd "$SADTALKER_DIR"

# Installation des dépendances
log_info "Installation des dépendances SadTalker..."
pip install -q -r requirements.txt 2>/dev/null || true
pip install -q gfpgan basicsr facexlib realesrgan 2>/dev/null || true

# Téléchargement des modèles
mkdir -p checkpoints
if [ ! -f "checkpoints/SadTalker_V0.0.2_512.safetensors" ]; then
    log_info "Téléchargement des modèles SadTalker..."
    bash scripts/download_models.sh 2>/dev/null || true
fi

mkdir -p gfpgan/weights
if [ ! -f "gfpgan/weights/GFPGANv1.4.pth" ]; then
    wget -q --show-progress -O gfpgan/weights/GFPGANv1.4.pth \
        "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth" || true
fi

# Exécution SadTalker
log_info "Génération de la vidéo..."
python inference.py \
    --driven_audio "$WORK_DIR/input/audio.wav" \
    --source_image "$WORK_DIR/input/avatar.$IMAGE_EXT" \
    --result_dir "$OUTPUT_DIR/sadtalker" \
    --preprocess full \
    --enhancer gfpgan \
    --size 512 \
    --expression_scale 1.2 \
    --pose_style 20 \
    --batch_size 2

# Trouver la vidéo générée
SADTALKER_OUTPUT=$(find "$OUTPUT_DIR/sadtalker" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -z "$SADTALKER_OUTPUT" ] || [ ! -f "$SADTALKER_OUTPUT" ]; then
    log_error "Aucune vidéo générée par SadTalker"
    exit 1
fi

# Copier vers output final
cp "$SADTALKER_OUTPUT" "$OUTPUT_DIR/final_output.mp4"
FINAL_OUTPUT="$OUTPUT_DIR/final_output.mp4"

log_info "✅ Vidéo générée: $FINAL_OUTPUT"

# =============================================================================
# FINALISATION
# =============================================================================
echo ""
log_step "Finalisation..."

echo ""
echo "=========================================="
echo -e "${GREEN}  ✅ GÉNÉRATION TERMINÉE !${NC}"
echo "=========================================="
echo ""

log_info "Informations vidéo:"
ffprobe -v quiet -show_entries format=duration,size -show_entries stream=width,height,codec_name -of default=noprint_wrappers=1 "$FINAL_OUTPUT" 2>/dev/null | head -10
log_info "Taille: $(du -h "$FINAL_OUTPUT" | cut -f1)"

# Upload vers webhook
if [ -n "$WEBHOOK_URL" ]; then
    log_step "Upload de la vidéo vers webhook..."
    UPLOAD_RESPONSE=$(curl -s -X POST -F "file=@$FINAL_OUTPUT" "$WEBHOOK_URL")
    log_info "Upload terminé: $UPLOAD_RESPONSE"
fi

echo ""
echo "=========================================="
echo "  Fichier: $FINAL_OUTPUT"
echo "=========================================="
echo ""
