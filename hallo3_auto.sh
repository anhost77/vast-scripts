#!/bin/bash
# =============================================================================
# HALLO3 - Vast.ai
# SCRIPT BASÉ SUR LA DOC OFFICIELLE
# https://github.com/fudan-generative-vision/hallo3
# 
# System requirement: Ubuntu 20.04/Ubuntu 22.04, Cuda 12.1
# Tested GPUs: H100
#
# Usage: bash hallo3_auto.sh <image_url> <audio_url> [webhook_url]
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
HALLO_DIR="/workspace/hallo3"
IMAGE_URL="${1:-}"
AUDIO_URL="${2:-}"
WEBHOOK_URL="${3:-}"

# =============================================================================
# VÉRIFICATION DES ARGUMENTS
# =============================================================================
if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo ""
    echo "=========================================="
    echo "  Hallo3 - Highly Dynamic Portrait Animation"
    echo "=========================================="
    echo ""
    log_error "Arguments manquants !"
    echo ""
    echo "Usage: bash hallo3_auto.sh <image_url> <audio_url> [webhook_url]"
    echo ""
    echo "Exigences image source (selon doc):"
    echo "  - Reference image must be 1:1 or 3:2 aspect ratio"
    echo ""
    echo "Exigences audio (selon doc):"
    echo "  - Driving audio must be in WAV format"
    echo "  - Audio must be in English"
    echo "  - Ensure the vocals are clear; background music is acceptable"
    echo ""
    exit 1
fi

echo ""
echo "=========================================="
echo "  Hallo3 - Highly Dynamic Portrait Animation"
echo "  [CVPR 2025] Video Diffusion Transformer"
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
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
log_info "GPU: $GPU_NAME"
log_info "VRAM: ${GPU_MEM}MB"

if [ "$GPU_MEM" -lt 40000 ]; then
    log_warn "Hallo3 est optimisé pour H100 (80GB). GPU actuel: ${GPU_MEM}MB"
    log_warn "Peut fonctionner mais risque de manquer de VRAM sur vidéos longues"
fi

log_info "✅ GPU détecté"

# =============================================================================
# DÉPENDANCES SYSTÈME
# =============================================================================
log_step "Installation des dépendances système..."
apt-get update -qq
apt-get install -y -qq build-essential g++ cmake ffmpeg libgl1-mesa-glx libglib2.0-0 > /dev/null 2>&1
log_info "✅ Dépendances système installées"

# =============================================================================
# TÉLÉCHARGEMENT DES FICHIERS INPUT
# =============================================================================
log_step "Téléchargement des fichiers d'entrée..."

mkdir -p "$WORK_DIR/input"
mkdir -p "$WORK_DIR/output"

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

# Conversion audio en WAV (doc: "Driving audio must be in WAV format")
log_info "Conversion audio en WAV..."
ffmpeg -y -i "$WORK_DIR/input/audio_temp" -ar 16000 -ac 1 -acodec pcm_s16le "$WORK_DIR/input/audio.wav" -loglevel error || {
    log_warn "Conversion échouée, utilisation directe..."
    mv "$WORK_DIR/input/audio_temp" "$WORK_DIR/input/audio.wav"
}
rm -f "$WORK_DIR/input/audio_temp"

log_info "✅ Fichiers prêts"

# =============================================================================
# ÉTAPE 1: Download the codes (selon doc)
# git clone https://github.com/fudan-generative-vision/hallo3
# cd hallo3
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 1: Download the codes"
log_step "=========================================="

if [ ! -d "$HALLO_DIR" ]; then
    log_cmd "git clone https://github.com/fudan-generative-vision/hallo3"
    git clone https://github.com/fudan-generative-vision/hallo3 "$HALLO_DIR"
else
    log_info "Hallo3 déjà cloné"
fi

log_cmd "cd hallo3"
cd "$HALLO_DIR"

# =============================================================================
# ÉTAPE 2: Install packages with pip (selon doc)
# pip install -r requirements.txt
# apt-get install ffmpeg
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 2: Install packages with pip"
log_step "=========================================="

# Configurer CUDA_HOME pour la compilation
log_info "Configuration de CUDA_HOME..."

# Méthode 1: via nvidia-smi
if [ -z "$CUDA_HOME" ]; then
    CUDA_PATH=$(dirname $(dirname $(ldconfig -p | grep libcudart | head -1 | awk '{print $NF}' 2>/dev/null)) 2>/dev/null)
    if [ -d "$CUDA_PATH" ]; then
        export CUDA_HOME=$CUDA_PATH
    fi
fi

# Méthode 2: chercher dans les chemins standards
if [ -z "$CUDA_HOME" ] || [ ! -d "$CUDA_HOME" ]; then
    for cuda_path in /usr/local/cuda-12.1 /usr/local/cuda-12 /usr/local/cuda /opt/conda/lib; do
        if [ -d "$cuda_path" ]; then
            export CUDA_HOME=$cuda_path
            break
        fi
    done
fi

# Méthode 3: utiliser torch pour trouver CUDA
if [ -z "$CUDA_HOME" ] || [ ! -d "$CUDA_HOME" ]; then
    TORCH_CUDA=$(python3 -c "import torch; print(torch.utils.cmake_prefix_path)" 2>/dev/null | head -1)
    if [ -n "$TORCH_CUDA" ]; then
        export CUDA_HOME=$(dirname $(dirname $TORCH_CUDA))
    fi
fi

export PATH=$CUDA_HOME/bin:$PATH 2>/dev/null || true
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH 2>/dev/null || true
log_info "CUDA_HOME: ${CUDA_HOME:-'(non trouvé, pas grave pour inference)'}"

# Installer TOUTES les dépendances du requirements.txt SAUF deepspeed
log_info "Installation des dépendances Python..."

# Core dependencies
pip install omegaconf==2.3.0 2>&1 | tail -1
pip install imageio==2.34.2 imageio-ffmpeg==0.5.1 2>&1 | tail -1
pip install einops==0.8.0 decord==0.6.0 2>&1 | tail -1
pip install opencv-python==4.10.0.84 opencv-contrib-python==4.10.0.84 2>&1 | tail -1
pip install transformers==4.45.2 2>&1 | tail -1
pip install accelerate 2>&1 | tail -1
pip install insightface==0.7.3 2>&1 | tail -1
pip install onnxruntime-gpu==1.19.2 2>&1 | tail -1
pip install mediapipe==0.10.14 2>&1 | tail -1
pip install audio-separator==0.21.2 2>&1 | tail -1
pip install pytorch-lightning==2.3.3 2>&1 | tail -1
pip install safetensors==0.4.3 2>&1 | tail -1
pip install sentencepiece==0.2.0 2>&1 | tail -1
pip install rotary-embedding-torch==0.6.5 2>&1 | tail -1
pip install SwissArmyTransformer==0.4.12 2>&1 | tail -1

# Additional dependencies from requirements.txt
pip install albumentations==1.4.18 2>&1 | tail -1
pip install av==12.1.0 2>&1 | tail -1
pip install librosa==0.10.2.post1 2>&1 | tail -1
pip install moviepy==1.0.3 2>&1 | tail -1
pip install kornia==0.7.3 2>&1 | tail -1
pip install scikit-image==0.24.0 scikit-learn==1.5.2 2>&1 | tail -1
pip install soundfile==0.12.1 pydub==0.25.1 2>&1 | tail -1
pip install wandb==0.17.5 2>&1 | tail -1
pip install webdataset==0.2.100 2>&1 | tail -1
pip install ffmpegcv==0.3.15 2>&1 | tail -1

# Skip deepspeed - not needed for inference
log_info "Skipping deepspeed (not required for inference)"

log_info "✅ Packages installés"

# =============================================================================
# ÉTAPE 3: Download Pretrained Models (selon doc)
# pip install "huggingface_hub[cli]"
# huggingface-cli download fudan-generative-ai/hallo3 --local-dir ./pretrained_models
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 3: Download Pretrained Models"
log_step "=========================================="

log_cmd "pip install huggingface_hub"
pip install "huggingface_hub[cli]" 2>&1 | tail -3

# Vérifier si modèles déjà présents
if [ -d "./pretrained_models/hallo3" ] && [ -f "./pretrained_models/hallo3/latest" ]; then
    log_info "Modèles déjà téléchargés"
else
    log_info "Téléchargement des modèles depuis HuggingFace (peut prendre 15-30 min)..."
    log_cmd "huggingface-cli download fudan-generative-ai/hallo3 --local-dir ./pretrained_models"
    
    # Utiliser Python directement (plus fiable que CLI)
    python3 -c "
from huggingface_hub import snapshot_download
print('Téléchargement des modèles Hallo3...')
print('Cela peut prendre 15-30 minutes (modèles ~20GB+)...')
snapshot_download(repo_id='fudan-generative-ai/hallo3', local_dir='./pretrained_models')
print('Téléchargement terminé!')
"
fi

# Vérification structure (selon doc)
log_info "Vérification de la structure des modèles..."
echo "Contenu de ./pretrained_models/:"
ls -la ./pretrained_models/ 2>/dev/null | head -15

# Vérifier les modèles essentiels selon la doc:
# ./pretrained_models/hallo3/1/mp_rank_00_model_states.pt
# ./pretrained_models/cogvideox-5b-i2v-sat/
# ./pretrained_models/t5-v1_1-xxl/

MODELS_OK=true

if [ ! -d "./pretrained_models/hallo3" ]; then
    log_error "Dossier pretrained_models/hallo3 non trouvé!"
    MODELS_OK=false
fi

if [ ! -d "./pretrained_models/cogvideox-5b-i2v-sat" ]; then
    log_warn "Dossier cogvideox-5b-i2v-sat non trouvé"
fi

if [ ! -d "./pretrained_models/t5-v1_1-xxl" ]; then
    log_warn "Dossier t5-v1_1-xxl non trouvé"
fi

if [ "$MODELS_OK" = false ]; then
    log_error "Modèles incomplets!"
    exit 1
fi

log_info "✅ Modèles prêts"

# =============================================================================
# ÉTAPE 4: Run Inference (selon doc)
# Option 1: Gradio UI - python hallo3/app.py
# Option 2: Batch - bash scripts/inference_long_batch.sh ./examples/inference/input.txt ./output
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 4: Run Inference"
log_step "=========================================="

# Créer le fichier input.txt pour le batch processing
log_info "Création du fichier d'entrée..."
cat > "$WORK_DIR/input/input.txt" << EOF
$WORK_DIR/input/source.png|$WORK_DIR/input/audio.wav
EOF

log_info "Nettoyage cache GPU..."
python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true

# Méthode 1: Script batch (recommandé selon doc)
log_cmd "bash scripts/inference_long_batch.sh ./input.txt ./output"

log_info ""
log_info "Fichiers d'entrée:"
log_info "  - Image: $WORK_DIR/input/source.png"
log_info "  - Audio: $WORK_DIR/input/audio.wav"
log_info ""
log_info "Génération en cours (peut prendre 10-60 minutes selon durée audio)..."
echo ""

# Exécuter le script batch
if [ -f "scripts/inference_long_batch.sh" ]; then
    bash scripts/inference_long_batch.sh "$WORK_DIR/input/input.txt" "$WORK_DIR/output" 2>&1 | tee "$WORK_DIR/hallo3_inference.log"
else
    # Alternative: utiliser Python directement si le script batch n'existe pas
    log_warn "Script batch non trouvé, utilisation de Python directement..."
    
    python3 << EOF
import sys
sys.path.insert(0, '.')

# Essayer d'importer et exécuter l'inférence
try:
    from hallo3.inference import main as inference_main
    inference_main(
        source_image="$WORK_DIR/input/source.png",
        driving_audio="$WORK_DIR/input/audio.wav",
        output_dir="$WORK_DIR/output"
    )
except Exception as e:
    print(f"Erreur: {e}")
    # Fallback: chercher un autre point d'entrée
    import subprocess
    subprocess.run([
        "python", "hallo3/app.py",
        "--source_image", "$WORK_DIR/input/source.png",
        "--driving_audio", "$WORK_DIR/input/audio.wav",
        "--output_dir", "$WORK_DIR/output"
    ], check=True)
EOF
fi

# =============================================================================
# ÉTAPE 5: Récupération du résultat
# =============================================================================
echo ""
log_step "=========================================="
log_step "ÉTAPE 5: Récupération du résultat"
log_step "=========================================="

log_info "Recherche de la vidéo générée..."

FOUND_OUTPUT=""
for search_path in "$WORK_DIR/output" "$HALLO_DIR/output" "$HALLO_DIR/outputs" "$HALLO_DIR"; do
    if [ -d "$search_path" ]; then
        FOUND=$(find "$search_path" -maxdepth 3 -name "*.mp4" -type f -mmin -60 2>/dev/null | head -1)
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
    log_info "=== Dernières 200 lignes du log ==="
    tail -200 "$WORK_DIR/hallo3_inference.log" 2>/dev/null || true
    echo ""
    log_info "=== Contenu des dossiers ==="
    ls -laR "$WORK_DIR/output/" 2>/dev/null | head -30 || echo "(output vide)"
    ls -laR "$HALLO_DIR/output/" 2>/dev/null | head -30 || echo "(hallo3/output vide)"
    exit 1
fi

# Copier vers emplacement final
FINAL_OUTPUT="$WORK_DIR/output/hallo3_result.mp4"
cp "$FOUND_OUTPUT" "$FINAL_OUTPUT"

log_info "✅ Vidéo copiée vers: $FINAL_OUTPUT"

# =============================================================================
# FINALISATION
# =============================================================================
echo ""
echo "=========================================="
echo -e "${GREEN}  ✅ HALLO3 TERMINÉ AVEC SUCCÈS !${NC}"
echo "=========================================="
echo ""

log_info "Informations vidéo:"
ffprobe -v quiet -show_entries format=duration,size -show_entries stream=width,height -of default=noprint_wrappers=1 "$FINAL_OUTPUT" 2>/dev/null | head -10
log_info "Taille: $(du -h "$FINAL_OUTPUT" | cut -f1)"

# Upload vers webhook
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
