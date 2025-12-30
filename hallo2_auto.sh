#!/bin/bash
# =============================================================================
# HALLO2 - Vast.ai
# Animation portrait complet (visage + corps + mains)
# Basé sur la doc officielle: https://github.com/fudan-generative-vision/hallo2
# Requiert GPU 24GB+ (RTX 3090/4090/A100)
# Usage: bash hallo2_auto.sh <image_url> <audio_url> <webhook_url>
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
HALLO_DIR="/workspace/hallo2"
IMAGE_URL="${1:-}"
AUDIO_URL="${2:-}"
WEBHOOK_URL="${3:-}"

# =============================================================================
# VÉRIFICATION DES ARGUMENTS
# =============================================================================
if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo ""
    echo "=========================================="
    echo "  Hallo2 - Animation Portrait Complet"
    echo "=========================================="
    echo ""
    log_error "Arguments manquants !"
    echo ""
    echo "Usage: bash hallo2_auto.sh <image_url> <audio_url> [webhook_url]"
    echo ""
    echo "⚠️  Requiert GPU 24GB+ (RTX 3090/4090/A100)"
    echo ""
    echo "Exigences image source:"
    echo "  - Format carré (1:1)"
    echo "  - Visage = 50-70% de l'image"
    echo "  - Visage de face (angle < 30°)"
    echo ""
    echo "Exigences audio:"
    echo "  - Format WAV"
    echo "  - Voix claire (musique de fond OK)"
    echo ""
    exit 1
fi

echo ""
echo "=========================================="
echo "  Hallo2 - Animation Portrait Complet"
echo "=========================================="
echo ""
log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
[ -n "$WEBHOOK_URL" ] && log_info "Webhook: $WEBHOOK_URL"
echo ""

# =============================================================================
# VÉRIFICATION GPU
# =============================================================================
log_step "Vérification du GPU..."

GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
log_info "VRAM disponible: ${GPU_MEM}MB"

if [ "$GPU_MEM" -lt 20000 ]; then
    log_error "Hallo2 nécessite 24GB+ de VRAM. GPU actuel: ${GPU_MEM}MB"
    exit 1
fi

log_info "✅ GPU compatible"

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

log_info "Téléchargement de l'image..."
wget -q --show-progress -O "$WORK_DIR/input/source.$IMAGE_EXT" "$IMAGE_URL" || {
    log_error "Impossible de télécharger l'image"
    exit 1
}

log_info "Téléchargement de l'audio..."
wget -q --show-progress -O "$WORK_DIR/input/audio_original" "$AUDIO_URL" || {
    log_error "Impossible de télécharger l'audio"
    exit 1
}

# Conversion audio en WAV (requis par Hallo2)
log_info "Conversion audio en WAV..."
ffmpeg -y -i "$WORK_DIR/input/audio_original" -ar 16000 -ac 1 -acodec pcm_s16le "$WORK_DIR/input/audio.wav" -loglevel quiet || {
    log_warn "Conversion ffmpeg échouée, tentative alternative..."
    mv "$WORK_DIR/input/audio_original" "$WORK_DIR/input/audio.wav"
}

log_info "Fichiers prêts"

# =============================================================================
# INSTALLATION HALLO2 (selon doc officielle)
# =============================================================================
echo ""
log_step "=========================================="
log_step "Installation de Hallo2"
log_step "=========================================="
echo ""

if [ ! -d "$HALLO_DIR" ]; then
    log_info "Clonage de Hallo2..."
    git clone https://github.com/fudan-generative-vision/hallo2.git "$HALLO_DIR"
fi

cd "$HALLO_DIR"

# Installation des dépendances Python (selon doc: CUDA 11.8)
log_info "Installation des dépendances Python..."
pip install -q torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cu118 2>/dev/null || true
pip install -q -r requirements.txt 2>/dev/null || true

# =============================================================================
# TÉLÉCHARGEMENT DES MODÈLES (selon doc officielle)
# =============================================================================
log_step "Téléchargement des modèles pré-entraînés..."

# Vérifier si les modèles existent déjà
if [ ! -f "pretrained_models/hallo2/net.pth" ]; then
    log_info "Téléchargement depuis HuggingFace (peut prendre 10-15 min)..."
    
    pip install -q huggingface_hub 2>/dev/null || true
    
    # Télécharger tous les modèles d'un coup (comme dans la doc)
    huggingface-cli download fudan-generative-ai/hallo2 --local-dir ./pretrained_models 2>&1 | tail -10 || {
        log_warn "huggingface-cli échoué, essai avec Python..."
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='fudan-generative-ai/hallo2', local_dir='./pretrained_models')
print('Modèles téléchargés')
" 2>&1 | tail -5
    }
fi

# Vérifier structure des modèles
if [ ! -f "pretrained_models/hallo2/net.pth" ] && [ ! -f "pretrained_models/net.pth" ]; then
    log_error "Modèles Hallo2 non trouvés !"
    log_info "Structure attendue: pretrained_models/hallo2/net.pth"
    ls -la pretrained_models/ 2>/dev/null || true
    exit 1
fi

log_info "✅ Modèles prêts"

# =============================================================================
# GÉNÉRATION AVEC HALLO2
# =============================================================================
echo ""
log_step "=========================================="
log_step "Hallo2 - Génération vidéo"
log_step "=========================================="
echo ""

# Vider le cache GPU
log_info "Nettoyage cache GPU..."
python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true

# Lancer l'inférence (selon doc officielle: inference_long.py)
log_info "Génération de la vidéo (peut prendre 5-15 minutes)..."

python scripts/inference_long.py \
    --config ./configs/inference/long.yaml \
    --source_image "$WORK_DIR/input/source.$IMAGE_EXT" \
    --driving_audio "$WORK_DIR/input/audio.wav" \
    --pose_weight 1.0 \
    --face_weight 1.0 \
    --lip_weight 1.0 \
    --face_expand_ratio 1.2 \
    2>&1 | tee "$OUTPUT_DIR/hallo2.log"

# =============================================================================
# RECHERCHE DU FICHIER OUTPUT
# =============================================================================
log_step "Recherche du fichier généré..."

# Hallo2 sauvegarde dans ./output/ par défaut selon le config
FOUND_OUTPUT=""

# Chercher dans les emplacements possibles
for search_dir in "$HALLO_DIR/output" "$HALLO_DIR" "$OUTPUT_DIR" "/workspace"; do
    if [ -d "$search_dir" ]; then
        FOUND=$(find "$search_dir" -maxdepth 2 -name "*.mp4" -type f -mmin -10 2>/dev/null | head -1)
        if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
            FOUND_OUTPUT="$FOUND"
            break
        fi
    fi
done

if [ -z "$FOUND_OUTPUT" ]; then
    log_error "Aucune vidéo générée par Hallo2"
    echo ""
    log_info "=== Dernières lignes du log ==="
    tail -100 "$OUTPUT_DIR/hallo2.log" 2>/dev/null || true
    echo ""
    log_info "=== Contenu des dossiers ==="
    ls -la "$HALLO_DIR/output/" 2>/dev/null || true
    ls -la "$OUTPUT_DIR/" 2>/dev/null || true
    exit 1
fi

# Copier vers output final
cp "$FOUND_OUTPUT" "$OUTPUT_DIR/hallo2_output.mp4"
FINAL_OUTPUT="$OUTPUT_DIR/hallo2_output.mp4"

log_info "✅ Vidéo générée: $FINAL_OUTPUT"

# =============================================================================
# SUPER RÉSOLUTION (optionnel)
# =============================================================================
# Décommenter si tu veux une meilleure qualité (prend plus de temps)
# log_step "Amélioration de la résolution..."
# python scripts/video_sr.py \
#     --input_path "$FINAL_OUTPUT" \
#     --output_path "$OUTPUT_DIR/" \
#     --bg_upsampler realesrgan \
#     --face_upsample \
#     -w 1 -s 2

# =============================================================================
# FINALISATION
# =============================================================================
echo ""
log_step "Finalisation..."

echo ""
echo "=========================================="
echo -e "${GREEN}  ✅ HALLO2 TERMINÉ !${NC}"
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
