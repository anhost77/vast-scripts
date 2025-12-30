#!/bin/bash
# =============================================================================
# HALLO2 - Vast.ai
# Animation portrait complet (visage + corps + mains)
# Requiert GPU 24GB+ (RTX 3090/4090/A5000)
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
    echo "⚠️  Requiert GPU 24GB+ (RTX 3090/4090/A5000)"
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
    log_info "Utilisez une RTX 3090, RTX 4090, A5000 ou supérieur"
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

# Détection extension audio
AUDIO_EXT="${AUDIO_URL##*.}"
AUDIO_EXT="${AUDIO_EXT%%\?*}"
[ -z "$AUDIO_EXT" ] || [ ${#AUDIO_EXT} -gt 4 ] && AUDIO_EXT="wav"

log_info "Téléchargement de l'image..."
wget -q --show-progress -O "$WORK_DIR/input/source.$IMAGE_EXT" "$IMAGE_URL" || {
    log_error "Impossible de télécharger l'image"
    exit 1
}

log_info "Téléchargement de l'audio..."
wget -q --show-progress -O "$WORK_DIR/input/audio.$AUDIO_EXT" "$AUDIO_URL" || {
    log_error "Impossible de télécharger l'audio"
    exit 1
}

# Conversion audio en WAV 16kHz mono
if [ "$AUDIO_EXT" != "wav" ]; then
    ffmpeg -y -i "$WORK_DIR/input/audio.$AUDIO_EXT" -ar 16000 -ac 1 "$WORK_DIR/input/audio.wav" -loglevel quiet || {
        log_warn "Conversion échouée, copie simple..."
        cp "$WORK_DIR/input/audio.$AUDIO_EXT" "$WORK_DIR/input/audio.wav"
    }
else
    # Déjà WAV, juste normaliser
    ffmpeg -y -i "$WORK_DIR/input/audio.wav" -ar 16000 -ac 1 "$WORK_DIR/input/audio_converted.wav" -loglevel quiet && \
    mv "$WORK_DIR/input/audio_converted.wav" "$WORK_DIR/input/audio.wav" || true
fi

log_info "Fichiers prêts"

# =============================================================================
# INSTALLATION HALLO2
# =============================================================================
echo ""
log_step "=========================================="
log_step "Installation de Hallo2"
log_step "=========================================="
echo ""

HALLO_DIR="$WORK_DIR/hallo2"

if [ ! -d "$HALLO_DIR" ]; then
    log_info "Clonage de Hallo2..."
    git clone https://github.com/fudan-generative-vision/hallo2.git "$HALLO_DIR"
fi

cd "$HALLO_DIR"

# Installation des dépendances Python
log_info "Installation des dépendances Python..."
pip install -q -r requirements.txt 2>/dev/null || true
pip install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 2>/dev/null || true
pip install -q diffusers transformers accelerate omegaconf einops 2>/dev/null || true

# Téléchargement des modèles pré-entraînés
log_info "Téléchargement des modèles Hallo2 (peut prendre plusieurs minutes)..."

mkdir -p pretrained_models

# Vérifier si les modèles existent déjà
if [ ! -d "pretrained_models/hallo2" ]; then
    log_info "Téléchargement depuis HuggingFace..."
    
    # Méthode 1: huggingface-cli
    if command -v huggingface-cli &> /dev/null; then
        huggingface-cli download fudan-generative-ai/hallo2 --local-dir pretrained_models/hallo2 2>&1 | tail -5 || true
    fi
    
    # Méthode 2: Python si CLI échoue
    if [ ! -d "pretrained_models/hallo2" ] || [ -z "$(ls -A pretrained_models/hallo2 2>/dev/null)" ]; then
        log_warn "CLI échoué, essai avec Python..."
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='fudan-generative-ai/hallo2', local_dir='pretrained_models/hallo2')
print('Modèles téléchargés')
" 2>&1 | tail -5 || true
    fi
fi

# Télécharger aussi les modèles de base nécessaires (wav2vec, face analysis, etc.)
log_info "Téléchargement des modèles auxiliaires..."

# wav2vec pour l'audio
if [ ! -d "pretrained_models/wav2vec" ]; then
    python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='facebook/wav2vec2-base-960h', local_dir='pretrained_models/wav2vec')
" 2>/dev/null || true
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

# Créer le fichier de configuration
log_info "Création de la configuration..."

cat > "$WORK_DIR/input/config.yaml" << EOF
source_image: "$WORK_DIR/input/source.$IMAGE_EXT"
driving_audio: "$WORK_DIR/input/audio.wav"
output_path: "$OUTPUT_DIR/hallo2_output.mp4"
pose_weight: 1.0
face_weight: 1.0
lip_weight: 1.0
face_expand_ratio: 1.2
EOF

# Exécution de Hallo2
log_info "Génération de la vidéo (peut prendre plusieurs minutes)..."

# Vider le cache GPU
python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true

# Lancer l'inférence
python scripts/inference.py \
    --source_image "$WORK_DIR/input/source.$IMAGE_EXT" \
    --driving_audio "$WORK_DIR/input/audio.wav" \
    --output "$OUTPUT_DIR/hallo2_output.mp4" \
    2>&1 | tee "$OUTPUT_DIR/hallo2.log"

# Vérification du résultat
if [ ! -f "$OUTPUT_DIR/hallo2_output.mp4" ]; then
    # Essayer un autre chemin de sortie possible
    FOUND_OUTPUT=$(find "$OUTPUT_DIR" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    
    if [ -n "$FOUND_OUTPUT" ] && [ -f "$FOUND_OUTPUT" ]; then
        mv "$FOUND_OUTPUT" "$OUTPUT_DIR/hallo2_output.mp4"
    else
        log_error "Aucune vidéo générée par Hallo2"
        log_info "Consultez le log: $OUTPUT_DIR/hallo2.log"
        exit 1
    fi
fi

FINAL_OUTPUT="$OUTPUT_DIR/hallo2_output.mp4"
log_info "✅ Vidéo générée: $FINAL_OUTPUT"

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
