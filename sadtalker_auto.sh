#!/bin/bash
# =============================================================================
# SadTalker AUTO - Détection automatique de l'environnement Vast.ai
# Usage: bash sadtalker_auto.sh <image_url> <audio_url>
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
WORK_DIR="/workspace/sadtalker"
OUTPUT_DIR="/workspace/output"
IMAGE_URL="${1:-}"
AUDIO_URL="${2:-}"

# =============================================================================
# VÉRIFICATION DES ARGUMENTS
# =============================================================================
if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo ""
    echo "=========================================="
    echo "  SadTalker AUTO - Générateur de Talking Head"
    echo "=========================================="
    echo ""
    log_error "Arguments manquants !"
    echo ""
    echo "Usage: bash sadtalker_auto.sh <image_url> <audio_url>"
    echo ""
    echo "Exemple:"
    echo "  bash sadtalker_auto.sh https://exemple.com/avatar.png https://exemple.com/audio.mp3"
    echo ""
    exit 1
fi

echo ""
echo "=========================================="
echo "  SadTalker AUTO - Vast.ai"
echo "=========================================="
echo ""
log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
echo ""

# =============================================================================
# DÉTECTION DE L'ENVIRONNEMENT
# =============================================================================
log_step "Détection de l'environnement..."

PYTORCH_INSTALLED=false
CONDA_INSTALLED=false
CUDA_AVAILABLE=false

# Vérifier PyTorch
if python3 -c "import torch; print(torch.__version__)" 2>/dev/null; then
    PYTORCH_INSTALLED=true
    PYTORCH_VERSION=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null)
    log_info "✅ PyTorch détecté: $PYTORCH_VERSION"
else
    log_warn "❌ PyTorch non détecté"
fi

# Vérifier CUDA
if python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null | grep -q "True"; then
    CUDA_AVAILABLE=true
    CUDA_VERSION=$(python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null)
    log_info "✅ CUDA disponible: $CUDA_VERSION"
else
    log_warn "⚠️  CUDA non disponible (CPU mode)"
fi

# Vérifier Conda
if command -v conda &> /dev/null; then
    CONDA_INSTALLED=true
    log_info "✅ Conda détecté"
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
# INSTALLATION PYTORCH SI NÉCESSAIRE
# =============================================================================
if [ "$PYTORCH_INSTALLED" = false ]; then
    log_step "Installation de PyTorch..."
    
    # Installer via pip directement (plus simple que conda pour Vast)
    pip install --upgrade pip -q
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 -q
    
    # Vérifier l'installation
    if python3 -c "import torch; print(torch.__version__)" 2>/dev/null; then
        PYTORCH_VERSION=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null)
        log_info "✅ PyTorch installé: $PYTORCH_VERSION"
    else
        log_error "Échec de l'installation de PyTorch"
        exit 1
    fi
fi

# =============================================================================
# CLONAGE SADTALKER
# =============================================================================
log_step "Préparation de SadTalker..."

if [ ! -d "$WORK_DIR" ]; then
    log_info "Clonage du repository..."
    git clone --depth 1 https://github.com/OpenTalker/SadTalker.git "$WORK_DIR"
else
    log_info "SadTalker déjà présent"
fi

cd "$WORK_DIR"

# =============================================================================
# INSTALLATION DÉPENDANCES PYTHON
# =============================================================================
log_step "Installation des dépendances Python..."

pip install -q --upgrade pip

# Installer les requirements
pip install -q -r requirements.txt 2>/dev/null || {
    log_warn "Installation standard échouée, installation manuelle..."
    pip install -q numpy scipy pyyaml tqdm imageio imageio-ffmpeg
    pip install -q face_alignment dlib
    pip install -q kornia yacs pydub
}

# Dépendances supplémentaires pour l'enhancer
pip install -q gfpgan basicsr facexlib realesrgan 2>/dev/null || true

log_info "Dépendances Python installées"

# =============================================================================
# TÉLÉCHARGEMENT DES MODÈLES
# =============================================================================
log_step "Téléchargement des modèles pré-entraînés..."

mkdir -p checkpoints

# Essayer le script officiel d'abord
if [ ! -f "checkpoints/SadTalker_V0.0.2_512.safetensors" ]; then
    log_info "Téléchargement des modèles SadTalker..."
    
    # Méthode 1: Script officiel
    bash scripts/download_models.sh 2>/dev/null || {
        log_warn "Script officiel échoué, téléchargement direct depuis HuggingFace..."
        
        cd checkpoints
        
        # Modèles principaux
        [ ! -f "SadTalker_V0.0.2_256.safetensors" ] && \
            wget -q --show-progress -O SadTalker_V0.0.2_256.safetensors \
            "https://huggingface.co/vinthony/SadTalker/resolve/main/SadTalker_V0.0.2_256.safetensors" || true
        
        [ ! -f "SadTalker_V0.0.2_512.safetensors" ] && \
            wget -q --show-progress -O SadTalker_V0.0.2_512.safetensors \
            "https://huggingface.co/vinthony/SadTalker/resolve/main/SadTalker_V0.0.2_512.safetensors" || true
        
        [ ! -f "mapping_00109-model.pth.tar" ] && \
            wget -q --show-progress -O mapping_00109-model.pth.tar \
            "https://huggingface.co/vinthony/SadTalker/resolve/main/mapping_00109-model.pth.tar" || true
        
        [ ! -f "mapping_00229-model.pth.tar" ] && \
            wget -q --show-progress -O mapping_00229-model.pth.tar \
            "https://huggingface.co/vinthony/SadTalker/resolve/main/mapping_00229-model.pth.tar" || true
        
        # BFM Fitting (nécessaire pour le face reconstruction)
        if [ ! -d "../src/config" ] || [ ! -f "../src/config/BFM_Fitting/01_MorphableModel.mat" ]; then
            wget -q --show-progress -O BFM_Fitting.zip \
                "https://huggingface.co/vinthony/SadTalker/resolve/main/BFM_Fitting.zip" || true
            [ -f "BFM_Fitting.zip" ] && unzip -o -q BFM_Fitting.zip -d ../src/config/ && rm BFM_Fitting.zip
        fi
        
        cd "$WORK_DIR"
    }
else
    log_info "Modèles SadTalker déjà présents"
fi

# Modèle GFPGAN pour l'amélioration du visage
mkdir -p gfpgan/weights
if [ ! -f "gfpgan/weights/GFPGANv1.4.pth" ]; then
    log_info "Téléchargement de GFPGAN..."
    wget -q --show-progress -O gfpgan/weights/GFPGANv1.4.pth \
        "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth" || true
fi

log_info "Modèles prêts"

# =============================================================================
# TÉLÉCHARGEMENT DES FICHIERS INPUT
# =============================================================================
log_step "Téléchargement des fichiers d'entrée..."

mkdir -p input
mkdir -p "$OUTPUT_DIR"

# Déterminer les extensions
IMAGE_EXT="${IMAGE_URL##*.}"
IMAGE_EXT="${IMAGE_EXT%%\?*}"  # Enlever les paramètres URL
[ -z "$IMAGE_EXT" ] || [ ${#IMAGE_EXT} -gt 4 ] && IMAGE_EXT="png"

AUDIO_EXT="${AUDIO_URL##*.}"
AUDIO_EXT="${AUDIO_EXT%%\?*}"
[ -z "$AUDIO_EXT" ] || [ ${#AUDIO_EXT} -gt 4 ] && AUDIO_EXT="wav"

# Télécharger
log_info "Téléchargement de l'image..."
wget -q --show-progress -O "input/avatar.$IMAGE_EXT" "$IMAGE_URL" || {
    log_error "Impossible de télécharger l'image"
    exit 1
}

log_info "Téléchargement de l'audio..."
wget -q --show-progress -O "input/audio.$AUDIO_EXT" "$AUDIO_URL" || {
    log_error "Impossible de télécharger l'audio"
    exit 1
}

# Convertir l'audio en WAV si nécessaire (SadTalker préfère WAV)
if [ "$AUDIO_EXT" != "wav" ]; then
    log_info "Conversion de l'audio en WAV..."
    ffmpeg -y -i "input/audio.$AUDIO_EXT" -ar 16000 -ac 1 "input/audio.wav" -loglevel quiet
    AUDIO_EXT="wav"
fi

log_info "Fichiers prêts"

# =============================================================================
# EXÉCUTION SADTALKER
# =============================================================================
echo ""
log_step "=========================================="
log_step "Génération de la vidéo avec SadTalker..."
log_step "=========================================="
echo ""

# Paramètres de génération
# --still : réduit les mouvements de tête (plus stable)
# --preprocess crop : recadre automatiquement sur le visage
# --enhancer gfpgan : améliore la qualité du visage
# --size 512 : résolution de sortie

python inference.py \
    --driven_audio "input/audio.$AUDIO_EXT" \
    --source_image "input/avatar.$IMAGE_EXT" \
    --result_dir "$OUTPUT_DIR" \
    --still \
    --preprocess crop \
    --enhancer gfpgan \
    --size 512 \
    --expression_scale 1.0 \
    --pose_style 0 \
    --batch_size 2

# =============================================================================
# FINALISATION
# =============================================================================
echo ""
log_step "Finalisation..."

# Trouver le fichier généré (le plus récent)
OUTPUT_FILE=$(find "$OUTPUT_DIR" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
    # Copier avec un nom simple et prévisible
    cp "$OUTPUT_FILE" "$OUTPUT_DIR/final_output.mp4"
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}  ✅ GÉNÉRATION TERMINÉE !${NC}"
    echo "=========================================="
    echo ""
    log_info "Vidéo générée: $OUTPUT_DIR/final_output.mp4"
    echo ""
    
    # Afficher les infos de la vidéo
    log_info "Informations vidéo:"
    ffprobe -v quiet -show_entries format=duration,size -show_entries stream=width,height,codec_name -of default=noprint_wrappers=1 "$OUTPUT_DIR/final_output.mp4" 2>/dev/null | head -10
    
    echo ""
    log_info "Taille du fichier: $(du -h "$OUTPUT_DIR/final_output.mp4" | cut -f1)"
    echo ""
    
else
    echo ""
    echo "=========================================="
    echo -e "${RED}  ❌ ÉCHEC DE LA GÉNÉRATION${NC}"
    echo "=========================================="
    echo ""
    log_error "Aucune vidéo générée"
    log_error "Vérifiez les logs ci-dessus pour plus de détails"
    exit 1
fi

# =============================================================================
# NETTOYAGE OPTIONNEL
# =============================================================================
# Décommenter pour nettoyer les fichiers temporaires
# rm -rf input/
# log_info "Fichiers temporaires nettoyés"

echo "=========================================="
echo "  Fichier de sortie:"
echo "  $OUTPUT_DIR/final_output.mp4"
echo "=========================================="
echo ""
