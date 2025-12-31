#!/bin/bash
# =============================================================================
# HALLO3 - Script d'installation et inférence automatique
# Basé sur la documentation officielle: https://github.com/fudan-generative-vision/hallo3
# System requirement: Ubuntu 20.04/Ubuntu 22.04, Cuda 12.1
# Tested GPUs: H100
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
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}[STEP]${NC} $1"; }

echo "=========================================="
echo "  Hallo3 - CVPR 2025"
echo "=========================================="

if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    log_error "Arguments manquants !"
    echo "Usage: bash hallo3_auto.sh <image_url> <audio_url> [webhook_url]"
    exit 1
fi

log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
log_info "Webhook: $WEBHOOK_URL"

cd /workspace

# =============================================================================
# ÉTAPE 1: DÉPENDANCES SYSTÈME (selon doc: apt-get install ffmpeg)
# =============================================================================
log_step "Installation dépendances système..."
apt-get update -qq && apt-get install -y -qq ffmpeg git-lfs > /dev/null 2>&1
log_info "✅ Système OK"

# =============================================================================
# ÉTAPE 2: TÉLÉCHARGEMENT FICHIERS INPUT
# =============================================================================
log_step "Téléchargement fichiers..."
mkdir -p /workspace/input /workspace/output

# Télécharger image
wget -q -O /workspace/input/source.png "$IMAGE_URL" || curl -sL "$IMAGE_URL" -o /workspace/input/source.png

# Télécharger audio et convertir en WAV si nécessaire
wget -q -O /workspace/input/audio_raw "$AUDIO_URL" || curl -sL "$AUDIO_URL" -o /workspace/input/audio_raw
ffmpeg -y -i /workspace/input/audio_raw -ar 16000 -ac 1 /workspace/input/audio.wav > /dev/null 2>&1 || \
    mv /workspace/input/audio_raw /workspace/input/audio.wav

log_info "✅ Fichiers OK"

# =============================================================================
# ÉTAPE 3: CLONE HALLO3 (selon doc: git clone)
# =============================================================================
log_step "Clone Hallo3..."
if [ ! -d "/workspace/hallo3" ]; then
    git clone https://github.com/fudan-generative-vision/hallo3 /workspace/hallo3
fi
cd /workspace/hallo3
log_info "✅ Code OK"

# =============================================================================
# ÉTAPE 4: ENVIRONNEMENT PYTHON
# Fixer les versions compatibles avant pip install -r requirements.txt
# =============================================================================
log_step "Configuration environnement Python..."

# Fixer numpy (éviter numpy 2.x)
pip uninstall -y numpy 2>/dev/null || true
pip install numpy==1.26.4

# Mettre à jour PyTorch vers 2.4.0 (nécessaire pour transformers/deepspeed récents)
pip install torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 --index-url https://download.pytorch.org/whl/cu118

# Fixer transformers et wandb (versions compatibles avec numpy 1.26)
pip install transformers==4.44.0 wandb==0.12.21

# Vérification
python3 -c "import numpy; print(f'NumPy {numpy.__version__}')"
python3 -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')"

log_info "✅ Python base OK"

# =============================================================================
# ÉTAPE 5: INSTALLATION REQUIREMENTS (selon doc: pip install -r requirements.txt)
# =============================================================================
log_step "Installation requirements.txt..."

# Installer les requirements (certains peuvent échouer, on continue)
pip install -r requirements.txt 2>&1 | grep -v "^Requirement already" | tail -5 || true

# Packages critiques qui peuvent manquer
pip install kornia omegaconf einops decord imageio imageio-ffmpeg
pip install mediapipe insightface onnxruntime-gpu
pip install audio-separator pytorch-lightning
pip install icetk icecream
pip install SwissArmyTransformer==0.4.12
pip install moviepy==1.0.3 av

log_info "✅ Requirements OK"

# =============================================================================
# ÉTAPE 6: TÉLÉCHARGER MODÈLES (selon doc: huggingface-cli download)
# =============================================================================
log_step "Téléchargement modèles HuggingFace..."

pip install "huggingface_hub[cli]"

if [ ! -d "./pretrained_models/hallo3" ]; then
    log_info "Téléchargement modèles (~50GB, patience...)..."
    huggingface-cli download fudan-generative-ai/hallo3 --local-dir ./pretrained_models
else
    log_info "Modèles déjà présents"
fi

ls -la ./pretrained_models/
log_info "✅ Modèles OK"

# =============================================================================
# ÉTAPE 7: PRÉPARER INPUT FILE (selon doc: examples/inference/input.txt)
# Format: image_path audio_path "prompt" scale
# =============================================================================
log_step "Préparation inférence..."

cat > /workspace/input/input.txt << EOF
/workspace/input/source.png /workspace/input/audio.wav "A person talking naturally" 1.0
EOF

log_info "Input file créé:"
cat /workspace/input/input.txt

# =============================================================================
# ÉTAPE 8: LANCER INFÉRENCE (selon doc: bash scripts/inference_long_batch.sh)
# =============================================================================
log_step "Lancement génération vidéo..."
log_info "(Peut prendre 10-60 minutes selon durée audio)"

bash scripts/inference_long_batch.sh /workspace/input/input.txt /workspace/output 2>&1 | tee /workspace/hallo3_inference.log

# =============================================================================
# ÉTAPE 9: RÉCUPÉRER RÉSULTAT
# =============================================================================
log_step "Recherche vidéo générée..."

VIDEO_FILE=$(find /workspace/output -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "$VIDEO_FILE" ] && [ -f "$VIDEO_FILE" ]; then
    log_info "✅ Vidéo générée: $VIDEO_FILE"
    
    VIDEO_SIZE=$(stat -c%s "$VIDEO_FILE")
    log_info "Taille: $(numfmt --to=iec $VIDEO_SIZE)"
    
    # Envoyer webhook si fourni
    if [ -n "$WEBHOOK_URL" ]; then
        log_step "Envoi webhook..."
        
        HOSTNAME=$(hostname)
        
        if [ "$VIDEO_SIZE" -lt 52428800 ]; then
            # < 50MB: envoyer en base64
            VIDEO_BASE64=$(base64 -w 0 "$VIDEO_FILE")
            curl -s -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -d "{\"status\":\"success\",\"hostname\":\"$HOSTNAME\",\"video_base64\":\"$VIDEO_BASE64\",\"filename\":\"$(basename $VIDEO_FILE)\"}"
        else
            # > 50MB: envoyer juste le chemin
            curl -s -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -d "{\"status\":\"success\",\"hostname\":\"$HOSTNAME\",\"video_path\":\"$VIDEO_FILE\",\"size\":$VIDEO_SIZE}"
        fi
        
        log_info "✅ Webhook envoyé"
    fi
else
    log_error "Aucune vidéo générée!"
    log_info "=== Dernières lignes du log ==="
    tail -30 /workspace/hallo3_inference.log
    
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"error\",\"message\":\"No video generated\",\"log\":\"$(tail -10 /workspace/hallo3_inference.log | tr '\n' ' ')\"}"
    fi
    
    exit 1
fi

log_info "🎉 Terminé avec succès!"
