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
if [ ! -f "/workspace/hallo3/pretrained_models/hallo3/latest" ]; then
    log_info "Modèles manquants, téléchargement en cours..."
    
    cd /workspace/hallo3
    
    # Supprimer dossier incomplet si existe
    rm -rf pretrained_models
    
    # Télécharger TOUS les modèles avec huggingface-cli (comme l'image Docker)
    huggingface-cli download fudan-generative-ai/hallo3 --local-dir ./pretrained_models
    
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
