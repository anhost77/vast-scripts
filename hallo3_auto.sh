#!/bin/bash
# =============================================================================
# HALLO3 AUTO - Script automatisé pour Vast.ai
# Animation portrait corps entier avec Video Diffusion Transformer
# =============================================================================

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# ARGUMENTS
# =============================================================================
IMAGE_URL="$1"
AUDIO_URL="$2"
WEBHOOK_URL="${3:-}"

if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo "=========================================="
    echo "  Hallo3 - Highly Dynamic Portrait Animation"
    echo "=========================================="
    log_error "Arguments manquants !"
    echo "Usage: bash hallo3_auto.sh <image_url> <audio_url> [webhook_url]"
    exit 1
fi

echo "=========================================="
echo "  Hallo3 - CVPR 2025"
echo "=========================================="
log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
log_info "Webhook: ${WEBHOOK_URL:-'(non défini)'}"

WORK_DIR="/workspace"
HALLO_DIR="$WORK_DIR/hallo3"
cd "$WORK_DIR"

# =============================================================================
# ÉTAPE 1: DÉPENDANCES SYSTÈME
# =============================================================================
log_step "Installation dépendances système..."
apt-get update -qq
apt-get install -y -qq build-essential g++ cmake ffmpeg libgl1-mesa-glx libglib2.0-0 git-lfs > /dev/null 2>&1
mkdir -p ~/.ssh
ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts 2>/dev/null
log_info "✅ Système OK"

# =============================================================================
# ÉTAPE 2: TÉLÉCHARGER INPUTS
# =============================================================================
log_step "Téléchargement fichiers..."
mkdir -p "$WORK_DIR/input" "$WORK_DIR/output"

wget -q -O "$WORK_DIR/input/source.png" "$IMAGE_URL" || { log_error "Échec image"; exit 1; }
wget -q -O "$WORK_DIR/input/audio_temp" "$AUDIO_URL" || { log_error "Échec audio"; exit 1; }
ffmpeg -y -i "$WORK_DIR/input/audio_temp" -ar 16000 -ac 1 -acodec pcm_s16le "$WORK_DIR/input/audio.wav" -loglevel error
rm -f "$WORK_DIR/input/audio_temp"
log_info "✅ Fichiers OK"

# =============================================================================
# ÉTAPE 3: CLONE HALLO3
# =============================================================================
log_step "Clone Hallo3..."
if [ ! -d "$HALLO_DIR" ]; then
    git clone --depth 1 https://github.com/fudan-generative-vision/hallo3 "$HALLO_DIR"
fi
cd "$HALLO_DIR"
log_info "✅ Code OK"

# =============================================================================
# ÉTAPE 4: ENVIRONNEMENT PYTHON - FIXER NUMPY D'ABORD
# =============================================================================
log_step "Configuration environnement Python..."

# CRITIQUE: Fixer numpy AVANT tout autre import
pip uninstall -y numpy 2>/dev/null || true
pip install numpy==1.26.4 --quiet

# Vérifier numpy
python3 -c "import numpy; print(f'NumPy {numpy.__version__}')"

# Vérifier torch
python3 -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')" || {
    log_info "Installation PyTorch..."
    pip install torch==2.4.0 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 --quiet
}

log_info "✅ Python base OK"

# =============================================================================
# ÉTAPE 5: INSTALLER SAT (SwissArmyTransformer) - CRITIQUE
# =============================================================================
log_step "Installation SwissArmyTransformer (sat)..."

# Définir CUDA_HOME pour deepspeed
export CUDA_HOME=/usr/local/cuda
if [ ! -d "$CUDA_HOME" ]; then
    # Chercher CUDA ailleurs
    for p in /usr/local/cuda-12.1 /usr/local/cuda-12 /usr/local/cuda-11.8 /opt/conda/pkgs/cuda-toolkit; do
        if [ -d "$p" ]; then
            export CUDA_HOME=$p
            break
        fi
    done
fi

# Si toujours pas trouvé, utiliser le chemin de nvcc
if [ ! -d "$CUDA_HOME" ]; then
    NVCC_PATH=$(which nvcc 2>/dev/null || find /usr -name "nvcc" 2>/dev/null | head -1)
    if [ -n "$NVCC_PATH" ]; then
        export CUDA_HOME=$(dirname $(dirname $NVCC_PATH))
    fi
fi

export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH
log_info "CUDA_HOME: $CUDA_HOME"

# Installer deepspeed d'abord
log_info "Installation deepspeed..."
DS_BUILD_OPS=0 pip install deepspeed --quiet 2>/dev/null || pip install deepspeed --quiet 2>/dev/null || true

# Dépendance de SAT
pip install icetk --quiet 2>/dev/null || true

# Installer SAT
pip install SwissArmyTransformer==0.4.12 --quiet 2>/dev/null || \
pip install git+https://github.com/THUDM/SwissArmyTransformer.git --quiet 2>/dev/null || true

# Vérification FINALE obligatoire
python3 -c "import sat; print('SAT OK')" || {
    log_error "ÉCHEC CRITIQUE: SwissArmyTransformer impossible à installer"
    exit 1
}
log_info "✅ SAT OK"

# =============================================================================
# ÉTAPE 6: AUTRES DÉPENDANCES (en batch pour vitesse)
# =============================================================================
log_step "Installation autres dépendances..."

pip install --quiet omegaconf==2.3.0 imageio==2.34.2 imageio-ffmpeg==0.5.1 2>/dev/null || true
pip install --quiet einops==0.8.0 decord==0.6.0 icecream 2>/dev/null || true
pip install --quiet opencv-python transformers==4.45.2 accelerate 2>/dev/null || true
pip install --quiet safetensors==0.4.3 sentencepiece==0.2.0 2>/dev/null || true
pip install --quiet mediapipe==0.10.14 2>/dev/null || true
pip install --quiet insightface==0.7.3 onnxruntime-gpu 2>/dev/null || true
pip install --quiet rotary-embedding-torch==0.6.5 2>/dev/null || true
pip install --quiet audio-separator==0.21.2 2>/dev/null || true
pip install --quiet pytorch-lightning==2.3.3 2>/dev/null || true
pip install --quiet kornia librosa soundfile av albumentations scikit-image 2>/dev/null || true

log_info "✅ Dépendances OK"

# =============================================================================
# ÉTAPE 7: TÉLÉCHARGER MODÈLES
# =============================================================================
log_step "Téléchargement modèles HuggingFace..."

pip install "huggingface_hub[cli]" --quiet

if [ ! -f "./pretrained_models/hallo3/latest" ]; then
    log_info "Téléchargement modèles (~20GB, patience...)..."
    python3 << 'PYEOF'
from huggingface_hub import snapshot_download
snapshot_download(repo_id='fudan-generative-ai/hallo3', local_dir='./pretrained_models')
print('Modèles téléchargés!')
PYEOF
else
    log_info "Modèles déjà présents"
fi

# Vérifier structure
ls -la ./pretrained_models/
log_info "✅ Modèles OK"

# =============================================================================
# ÉTAPE 8: CRÉER INPUT FILE
# =============================================================================
log_step "Préparation inférence..."

cat > "$WORK_DIR/input/input.txt" << EOF
$WORK_DIR/input/source.png $WORK_DIR/input/audio.wav "A person talking naturally" 1.0
EOF

log_info "Input file créé:"
cat "$WORK_DIR/input/input.txt"

# =============================================================================
# ÉTAPE 9: INFÉRENCE
# =============================================================================
log_step "Lancement génération vidéo..."
log_info "(Peut prendre 10-60 minutes selon durée audio)"

# Clear GPU cache
python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true

# Variables d'environnement
export CUDA_VISIBLE_DEVICES=0

# Lancer inference
cd "$HALLO_DIR"
bash scripts/inference_long_batch.sh "$WORK_DIR/input/input.txt" "$WORK_DIR/output" 2>&1 | tee "$WORK_DIR/inference.log"

# =============================================================================
# ÉTAPE 10: RÉCUPÉRATION RÉSULTAT
# =============================================================================
log_step "Recherche vidéo générée..."

OUTPUT_VIDEO=$(find "$WORK_DIR/output" -name "*.mp4" -type f 2>/dev/null | head -1)

if [ -z "$OUTPUT_VIDEO" ]; then
    log_error "Aucune vidéo générée!"
    log_info "=== Dernières lignes du log ==="
    tail -50 "$WORK_DIR/inference.log" 2>/dev/null || true
    log_info "=== Contenu output ==="
    ls -la "$WORK_DIR/output/" 2>/dev/null || true
    exit 1
fi

log_info "Vidéo trouvée: $OUTPUT_VIDEO"
FINAL_VIDEO="$WORK_DIR/output/hallo3_result.mp4"
cp "$OUTPUT_VIDEO" "$FINAL_VIDEO"

# =============================================================================
# ÉTAPE 11: WEBHOOK
# =============================================================================
if [ -n "$WEBHOOK_URL" ]; then
    log_step "Envoi webhook..."
    
    FILE_SIZE=$(stat -c%s "$FINAL_VIDEO")
    log_info "Taille vidéo: $FILE_SIZE bytes"
    
    if [ "$FILE_SIZE" -gt 50000000 ]; then
        log_warn "Fichier trop gros pour webhook base64, envoi URL seulement"
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"status\": \"success\", \"message\": \"Video too large for base64\", \"size\": $FILE_SIZE}" \
            --max-time 30 || true
    else
        VIDEO_BASE64=$(base64 -w 0 "$FINAL_VIDEO")
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"status\": \"success\", \"video_base64\": \"$VIDEO_BASE64\", \"filename\": \"hallo3_result.mp4\"}" \
            --max-time 300 || log_warn "Webhook échoué"
    fi
fi

log_info "=========================================="
log_info "✅ TERMINÉ AVEC SUCCÈS!"
log_info "Vidéo: $FINAL_VIDEO"
log_info "=========================================="
