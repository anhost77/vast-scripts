#!/bin/bash
# =============================================================================
# HALLO2 - Vast.ai
# SCRIPT BASÉ EXACTEMENT SUR LA DOC OFFICIELLE
# https://github.com/fudan-generative-vision/hallo2
# 
# System requirement: Ubuntu 20.04/Ubuntu 22.04, Cuda 11.8
# Tested GPUs: A100 (fonctionne aussi sur RTX 4090 24GB)
#
# Usage: bash hallo2_auto.sh <image_url> <audio_url> [webhook_url]
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
log_cmd() { echo -e "${YELLOW}[CMD]${NC} $1"; }

# =============================================================================
# CONFIGURATION
# =============================================================================
WORK_DIR="/workspace"
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
    echo "Exigences image source (selon doc):"
    echo "  - It should be cropped into squares"
    echo "  - The face should be the main focus, making up 50%-70% of the image"
    echo "  - The face should be facing forward, with a rotation angle of less than 30°"
    echo ""
    echo "Exigences audio (selon doc):"
    echo "  - It must be in WAV format"
    echo "  - It must be in English since training datasets are only in this language"
    echo "  - Ensure the vocals are clear; background music is acceptable"
    echo ""
    exit 1
fi

echo ""
echo "=========================================="
echo "  Hallo2 - Animation Portrait Complet"
echo "  (Selon doc officielle GitHub)"
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
log_info "✅ GPU détecté"

# =============================================================================
# TÉLÉCHARGEMENT DES FICHIERS INPUT
# =============================================================================
log_step "Téléchargement des fichiers d'entrée..."

mkdir -p "$WORK_DIR/input"

# Image
log_info "Téléchargement de l'image..."
wget -q --show-progress -O "$WORK_DIR/input/source.png" "$IMAGE_URL" || {
    log_error "Impossible de télécharger l'image"
    exit 1
}

# Audio
log_info "Téléchargement de l'audio..."
wget -q --show-progress -O "$WORK_DIR/input/audio_temp" "$AUDIO_URL" || {
    log_error "Impossible de télécharger l'audio"
    exit 1
}

# Conversion audio en WAV (doc: "It must be in WAV format")
log_info "Conversion audio en WAV..."
ffmpeg -y -i "$WORK_DIR/input/audio_temp" -ar 16000 -ac 1 -acodec pcm_s16le "$WORK_DIR/input/audio.wav" -loglevel error || {
    log_warn "Conversion échouée, utilisation directe..."
    mv "$WORK_DIR/input/audio_temp" "$WORK_DIR/input/audio.wav"
}
rm -f "$WORK_DIR/input/audio_temp"

log_info "✅ Fichiers prêts"
log_info "  - Image: $WORK_DIR/input/source.png"
log_info "  - Audio: $WORK_DIR/input/audio.wav"

# =============================================================================
# ÉTAPE 1: Download the codes (selon doc)
# git clone https://github.com/fudan-generative-vision/hallo2
# cd hallo2
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 1: Download the codes"
log_step "=========================================="

if [ ! -d "$HALLO_DIR" ]; then
    log_cmd "git clone https://github.com/fudan-generative-vision/hallo2"
    git clone https://github.com/fudan-generative-vision/hallo2 "$HALLO_DIR"
else
    log_info "Hallo2 déjà cloné"
fi

log_cmd "cd hallo2"
cd "$HALLO_DIR"

# =============================================================================
# ÉTAPE 2: Install packages with pip (selon doc)
# pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cu118
# pip install -r requirements.txt
# apt-get install ffmpeg
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 2: Install packages with pip"
log_step "=========================================="

log_cmd "pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cu118"
pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cu118 2>&1 | tail -10

log_cmd "pip install -r requirements.txt"
pip install -r requirements.txt 2>&1 | tail -10

log_cmd "apt-get install ffmpeg"
apt-get update -qq && apt-get install -y -qq ffmpeg > /dev/null 2>&1

log_info "✅ Packages installés"

# =============================================================================
# ÉTAPE 3: Download Pretrained Models (selon doc)
# pip install huggingface_hub
# huggingface-cli download fudan-generative-ai/hallo2 --local-dir ./pretrained_models
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 3: Download Pretrained Models"
log_step "=========================================="

log_cmd "pip install huggingface_hub"
pip install huggingface_hub 2>&1 | tail -3

# Vérifier si modèles déjà présents (structure selon doc)
if [ -f "./pretrained_models/hallo2/net.pth" ]; then
    log_info "Modèles déjà téléchargés"
else
    log_cmd "huggingface-cli download fudan-generative-ai/hallo2 --local-dir ./pretrained_models"
    huggingface-cli download fudan-generative-ai/hallo2 --local-dir ./pretrained_models 2>&1 | tail -20
fi

# Vérification structure (selon doc):
# ./pretrained_models/hallo2/net_g.pth et net.pth
log_info "Vérification de la structure des modèles..."
echo "Contenu de ./pretrained_models/:"
ls -la ./pretrained_models/ 2>/dev/null || true
echo ""
echo "Contenu de ./pretrained_models/hallo2/:"
ls -la ./pretrained_models/hallo2/ 2>/dev/null || true

if [ ! -f "./pretrained_models/hallo2/net.pth" ] && [ ! -f "./pretrained_models/hallo2/net_g.pth" ]; then
    log_error "Modèles hallo2 non trouvés!"
    log_info "Structure attendue selon doc:"
    echo "./pretrained_models/"
    echo "|-- hallo2"
    echo "|   |-- net_g.pth"
    echo "|   \`-- net.pth"
    exit 1
fi

log_info "✅ Modèles prêts"

# =============================================================================
# ÉTAPE 4: Run Inference (selon doc)
# python scripts/inference_long.py --config ./configs/inference/long.yaml
# 
# Options disponibles selon doc:
#   --source_image SOURCE_IMAGE
#   --driving_audio DRIVING_AUDIO
#   --pose_weight POSE_WEIGHT
#   --face_weight FACE_WEIGHT
#   --lip_weight LIP_WEIGHT
#   --face_expand_ratio FACE_EXPAND_RATIO
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 4: Run Inference"
log_step "=========================================="

log_info "Nettoyage cache GPU..."
python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true

log_cmd "python scripts/inference_long.py --config ./configs/inference/long.yaml --source_image ... --driving_audio ..."

log_info ""
log_info "Paramètres:"
log_info "  --source_image: $WORK_DIR/input/source.png"
log_info "  --driving_audio: $WORK_DIR/input/audio.wav"
log_info "  --pose_weight: 1.0"
log_info "  --face_weight: 1.0"
log_info "  --lip_weight: 1.0"
log_info "  --face_expand_ratio: 1.2"
log_info ""
log_info "Génération en cours (peut prendre 5-20 minutes selon durée audio)..."
echo ""

python scripts/inference_long.py \
    --config ./configs/inference/long.yaml \
    --source_image "$WORK_DIR/input/source.png" \
    --driving_audio "$WORK_DIR/input/audio.wav" \
    --pose_weight 1.0 \
    --face_weight 1.0 \
    --lip_weight 1.0 \
    --face_expand_ratio 1.2 \
    2>&1 | tee "$WORK_DIR/hallo2_inference.log"

# =============================================================================
# ÉTAPE 5: Récupération du résultat
# Selon doc: "Animation results will be saved at save_path"
# Par défaut dans ./output/ ou configuré dans long.yaml
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 5: Récupération du résultat"
log_step "=========================================="

log_info "Recherche de la vidéo générée..."

# Chercher dans les emplacements possibles
FOUND_OUTPUT=""
for search_path in \
    "$HALLO_DIR/output" \
    "$HALLO_DIR/outputs" \
    "$HALLO_DIR" \
    "/workspace/output" \
    "/workspace"; do
    
    if [ -d "$search_path" ]; then
        # Chercher fichiers mp4 créés dans les 30 dernières minutes
        FOUND=$(find "$search_path" -maxdepth 3 -name "*.mp4" -type f -mmin -30 2>/dev/null | head -1)
        if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
            FOUND_OUTPUT="$FOUND"
            log_info "Vidéo trouvée: $FOUND_OUTPUT"
            break
        fi
    fi
done

if [ -z "$FOUND_OUTPUT" ]; then
    log_error "Aucune vidéo générée!"
    echo ""
    log_info "=== Dernières 150 lignes du log ==="
    tail -150 "$WORK_DIR/hallo2_inference.log" 2>/dev/null || true
    echo ""
    log_info "=== Contenu des dossiers ==="
    echo "--- $HALLO_DIR/output/ ---"
    ls -la "$HALLO_DIR/output/" 2>/dev/null || echo "(vide ou inexistant)"
    echo "--- $HALLO_DIR/ ---"
    ls -la "$HALLO_DIR/"*.mp4 2>/dev/null || echo "(pas de mp4)"
    exit 1
fi

# Copier vers emplacement final
mkdir -p "$WORK_DIR/output"
FINAL_OUTPUT="$WORK_DIR/output/hallo2_result.mp4"
cp "$FOUND_OUTPUT" "$FINAL_OUTPUT"

log_info "✅ Vidéo copiée vers: $FINAL_OUTPUT"

# =============================================================================
# FINALISATION
# =============================================================================
echo ""
echo "=========================================="
echo -e "${GREEN}  ✅ HALLO2 TERMINÉ AVEC SUCCÈS !${NC}"
echo "=========================================="
echo ""

log_info "Informations vidéo:"
ffprobe -v quiet -show_entries format=duration,size -show_entries stream=width,height -of default=noprint_wrappers=1 "$FINAL_OUTPUT" 2>/dev/null | head -10
log_info "Taille: $(du -h "$FINAL_OUTPUT" | cut -f1)"

# Upload vers webhook si spécifié
if [ -n "$WEBHOOK_URL" ]; then
    echo ""
    log_step "Upload vers webhook..."
    UPLOAD_RESPONSE=$(curl -s -X POST -F "file=@$FINAL_OUTPUT" "$WEBHOOK_URL")
    log_info "Réponse: $UPLOAD_RESPONSE"
fi

echo ""
echo "=========================================="
echo "  Fichier final: $FINAL_OUTPUT"
echo "=========================================="
echo ""
