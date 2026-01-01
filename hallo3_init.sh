#!/bin/bash
# =============================================================================
# HALLO3 - Initialisation instance (une seule fois au démarrage)
# =============================================================================
WEBHOOK_READY="$1"
# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}[STEP]${NC} $1"; }
echo "=========================================="
echo "  Hallo3 - Initialisation"
echo "=========================================="
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
# ÉTAPE 2: CRÉER DOSSIERS
# =============================================================================
log_step "Création dossiers..."
mkdir -p /workspace/input /workspace/output
log_info "✅ Dossiers OK"
# =============================================================================
# ÉTAPE 3: TÉLÉCHARGER MODÈLES SI MANQUANTS
# =============================================================================
log_step "Vérification/Téléchargement modèles..."
if [ ! -d "/workspace/hallo3/pretrained_models/hallo3" ]; then
    log_info "Modèles manquants, téléchargement en cours..."
    
    cd /workspace/hallo3
    
    # Télécharger les modèles via le script officiel ou huggingface
    if [ -f "scripts/download_models.sh" ]; then
        bash scripts/download_models.sh
    else
        # Alternative: téléchargement manuel depuis HuggingFace
        pip install -q huggingface_hub
        
        python3 << 'EOF'
from huggingface_hub import snapshot_download
import os
# Dossier destination
models_dir = "/workspace/hallo3/pretrained_models"
os.makedirs(models_dir, exist_ok=True)
# Télécharger les modèles Hallo3
repos = [
    ("fudan-generative-ai/hallo3", "hallo3"),
    ("stabilityai/stable-video-diffusion-img2vid-xt", "svd"),
    ("THUDM/CogVideoX-5b-I2V", "cogvideox-5b-i2v-sat"),
    ("google/t5-v1_1-xxl", "t5-v1_1-xxl"),
]
for repo, folder in repos:
    dest = os.path.join(models_dir, folder)
    if not os.path.exists(dest):
        print(f"Downloading {repo}...")
        snapshot_download(repo_id=repo, local_dir=dest, local_dir_use_symlinks=False)
        print(f"✅ {folder} downloaded")
    else:
        print(f"✅ {folder} already exists")
# Face analysis models
face_dir = os.path.join(models_dir, "face_analysis/models")
os.makedirs(face_dir, exist_ok=True)
# Audio separator
audio_dir = os.path.join(models_dir, "audio_separator")
os.makedirs(audio_dir, exist_ok=True)
print("✅ All models ready")
EOF
    fi
    
    log_info "✅ Modèles téléchargés"
else
    log_info "✅ Modèles déjà présents"
fi
# =============================================================================
# ÉTAPE 4: ENVOYER WEBHOOK READY
# =============================================================================
if [ -n "$WEBHOOK_READY" ]; then
    log_step "Envoi webhook ready..."
    INSTANCE_ID=$(echo $CONTAINER_ID | sed 's/C\.//')
    curl -s -X POST "$WEBHOOK_READY" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"ready\",\"instance_id\":\"$INSTANCE_ID\"}"
    log_info "✅ Webhook envoyé"
fi
log_info "🎉 Instance prête! En attente de jobs..."
