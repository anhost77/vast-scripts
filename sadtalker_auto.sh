#!/bin/bash
# =============================================================================
# SadTalker + LatentSync AUTO - Vast.ai
# Usage: bash sadtalker_auto.sh <image_url> <audio_url> <webhook_url> <vast_instance_id> <vast_api_key>
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
VAST_INSTANCE_ID="${4:-}"
VAST_API_KEY="${5:-}"

# =============================================================================
# VÉRIFICATION DES ARGUMENTS
# =============================================================================
if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo ""
    echo "=========================================="
    echo "  SadTalker + LatentSync AUTO"
    echo "=========================================="
    echo ""
    log_error "Arguments manquants !"
    echo ""
    echo "Usage: bash sadtalker_auto.sh <image_url> <audio_url> [webhook_url] [vast_instance_id] [vast_api_key]"
    echo ""
    exit 1
fi

echo ""
echo "=========================================="
echo "  SadTalker + LatentSync AUTO - Vast.ai"
echo "=========================================="
echo ""
log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
[ -n "$WEBHOOK_URL" ] && log_info "Webhook: $WEBHOOK_URL"
[ -n "$VAST_INSTANCE_ID" ] && log_info "Instance ID: $VAST_INSTANCE_ID"
echo ""

# =============================================================================
# DÉTECTION DE L'ENVIRONNEMENT
# =============================================================================
log_step "Détection de l'environnement..."

if python3 -c "import torch; print(torch.__version__)" 2>/dev/null; then
    PYTORCH_VERSION=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null)
    log_info "✅ PyTorch détecté: $PYTORCH_VERSION"
fi

if python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null | grep -q "True"; then
    CUDA_VERSION=$(python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null)
    log_info "✅ CUDA disponible: $CUDA_VERSION"
fi

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

IMAGE_EXT="${IMAGE_URL##*.}"
IMAGE_EXT="${IMAGE_EXT%%\?*}"
[ -z "$IMAGE_EXT" ] || [ ${#IMAGE_EXT} -gt 4 ] && IMAGE_EXT="png"

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

# Optimisation audio
log_info "Optimisation de l'audio..."
if [ "$AUDIO_EXT" != "wav" ]; then
    ffmpeg -y -i "$WORK_DIR/input/audio.$AUDIO_EXT" -ar 16000 -ac 1 "$WORK_DIR/input/audio.wav" -loglevel quiet || {
        log_warn "Conversion simple de l'audio..."
        cp "$WORK_DIR/input/audio.$AUDIO_EXT" "$WORK_DIR/input/audio.wav"
    }
else
    # Déjà en WAV, on normalise juste le sample rate
    ffmpeg -y -i "$WORK_DIR/input/audio.wav" -ar 16000 -ac 1 "$WORK_DIR/input/audio_converted.wav" -loglevel quiet && \
    mv "$WORK_DIR/input/audio_converted.wav" "$WORK_DIR/input/audio.wav" || true
fi
AUDIO_EXT="wav"

log_info "Fichiers prêts"

# =============================================================================
# ÉTAPE 1 : SADTALKER - Animation du visage (sans parole)
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 1: SadTalker - Animation du visage"
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

# Créer un audio silencieux de même durée pour SadTalker (animation sans parole)
#AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORK_DIR/input/audio.wav")
#log_info "Durée audio: ${AUDIO_DURATION}s"

#log_info "Création audio silencieux pour animation..."
#ffmpeg -y -f lavfi -i anullsrc=r=16000:cl=mono -t "$AUDIO_DURATION" "$WORK_DIR/input/silent.wav" -loglevel quiet

# Exécution SadTalker avec audio silencieux (juste animation faciale)
# Exécution SadTalker avec le VRAI audio (mouvements de tête + expressions)
log_info "Génération de l'animation faciale..."
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
log_info "Vidéo SadTalker: $SADTALKER_OUTPUT"

# =============================================================================
# ÉTAPE 2 : LATENTSYNC - Synchronisation labiale
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 2: LatentSync - Synchronisation labiale"
log_step "=========================================="
echo ""

LATENTSYNC_DIR="/workspace/LatentSync"

if [ ! -d "$LATENTSYNC_DIR" ]; then
    log_info "Clonage de LatentSync..."
    git clone https://github.com/bytedance/LatentSync.git "$LATENTSYNC_DIR"
fi

cd "$LATENTSYNC_DIR"

# Installation de TOUTES les dépendances LatentSync avec versions compatibles
log_info "Installation des dépendances LatentSync..."
pip install -q "diffusers==0.24.0" omegaconf einops accelerate transformers safetensors huggingface_hub --break-system-packages 2>/dev/null || true
pip install -q -r requirements.txt --break-system-packages 2>/dev/null || true

# Téléchargement des modèles LatentSync (tous les checkpoints nécessaires)
if [ ! -f "checkpoints/latentsync_unet.pt" ]; then
    log_info "Téléchargement des modèles LatentSync..."
    mkdir -p checkpoints
    huggingface-cli download ByteDance/LatentSync-1.5 --local-dir checkpoints --quiet 2>/dev/null || {
        log_warn "HuggingFace CLI échoué, essai avec Python..."
        python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='ByteDance/LatentSync-1.5', local_dir='checkpoints')" 2>/dev/null || true
    }
fi

# Vérification que les modèles sont présents
if [ ! -f "checkpoints/latentsync_unet.pt" ]; then
    log_error "Modèles LatentSync non trouvés, skip LatentSync"
    FINAL_OUTPUT="$SADTALKER_OUTPUT"
else
    # Exécution LatentSync
    log_info "Génération du lip-sync avec LatentSync..."
    python -m scripts.inference \
        --unet_config_path "configs/unet/stage2.yaml" \
        --inference_ckpt_path "checkpoints/latentsync_unet.pt" \
        --inference_steps 20 \
        --guidance_scale 1.5 \
        --video_path "$SADTALKER_OUTPUT" \
        --audio_path "$WORK_DIR/input/audio.wav" \
        --video_out_path "$OUTPUT_DIR/final_output.mp4"
    
    if [ -f "$OUTPUT_DIR/final_output.mp4" ]; then
        FINAL_OUTPUT="$OUTPUT_DIR/final_output.mp4"
        log_info "✅ LatentSync terminé: $FINAL_OUTPUT"
    else
        log_warn "LatentSync a échoué, utilisation de la sortie SadTalker"
        FINAL_OUTPUT="$SADTALKER_OUTPUT"
    fi
fi

# =============================================================================
# FINALISATION
# =============================================================================
echo ""
log_step "Finalisation..."

if [ -f "$OUTPUT_DIR/final_output.mp4" ]; then
    echo ""
    echo "=========================================="
    echo -e "${GREEN}  ✅ GÉNÉRATION TERMINÉE !${NC}"
    echo "=========================================="
    echo ""
    log_info "Vidéo générée: $OUTPUT_DIR/final_output.mp4"
    echo ""
    
    log_info "Informations vidéo:"
    ffprobe -v quiet -show_entries format=duration,size -show_entries stream=width,height,codec_name -of default=noprint_wrappers=1 "$OUTPUT_DIR/final_output.mp4" 2>/dev/null | head -10
    
    echo ""
    log_info "Taille du fichier: $(du -h "$OUTPUT_DIR/final_output.mp4" | cut -f1)"
    echo ""
    
    # Upload vers n8n
    if [ -n "$WEBHOOK_URL" ]; then
        log_step "Upload de la vidéo vers n8n..."
        UPLOAD_RESPONSE=$(curl -s -X POST -F "file=@$OUTPUT_DIR/final_output.mp4" "$WEBHOOK_URL")
        log_info "Upload terminé: $UPLOAD_RESPONSE"
    fi
    
    # Destruction de l'instance Vast.ai
    if [ -n "$VAST_INSTANCE_ID" ] && [ -n "$VAST_API_KEY" ]; then
        log_step "Destruction de l'instance Vast.ai #$VAST_INSTANCE_ID..."
        DESTROY_RESPONSE=$(curl -s -X DELETE \
            -H "Authorization: Bearer $VAST_API_KEY" \
            "https://console.vast.ai/api/v0/instances/$VAST_INSTANCE_ID/")
        log_info "Instance détruite: $DESTROY_RESPONSE"
    fi
    
else
    echo ""
    echo "=========================================="
    echo -e "${RED}  ❌ ÉCHEC DE LA GÉNÉRATION${NC}"
    echo "=========================================="
    echo ""
    log_error "Aucune vidéo générée"
    exit 1
fi

echo ""
echo "=========================================="
echo "  Fichier de sortie:"
echo "  $OUTPUT_DIR/final_output.mp4"
echo "=========================================="
echo ""
