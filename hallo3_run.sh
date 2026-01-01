#!/bin/bash
# =============================================================================
# HALLO3 - Script d'inférence
# =============================================================================

set -e

IMAGE_URL="$1"
AUDIO_URL="$2"
WEBHOOK_URL="$3"
JOB_ID="$4"
WEBHOOK_ORCHESTRATOR="$5"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}[STEP]${NC} $1"; }

echo "=========================================="
echo "  Hallo3 - Job: $JOB_ID"
echo "=========================================="

if [ -z "$IMAGE_URL" ] || [ -z "$AUDIO_URL" ]; then
    log_error "Usage: bash hallo3_run.sh <image_url> <audio_url> <webhook_url> <job_id> [webhook_orchestrator]"
    exit 1
fi

log_info "Image: $IMAGE_URL"
log_info "Audio: $AUDIO_URL"
log_info "Webhook: $WEBHOOK_URL"
log_info "Job ID: $JOB_ID"
log_info "Orchestrator: $WEBHOOK_ORCHESTRATOR"

cd /workspace/hallo3

# =============================================================================
# ÉTAPE 1: NETTOYAGE
# =============================================================================
log_step "Nettoyage ancien job..."
rm -rf /workspace/input/* /workspace/output/*
log_info "✅ Nettoyage OK"

# =============================================================================
# ÉTAPE 2: TÉLÉCHARGEMENT FICHIERS INPUT
# =============================================================================
log_step "Téléchargement fichiers..."
mkdir -p /workspace/input /workspace/output

wget -q -O /workspace/input/source.png "$IMAGE_URL" || curl -sL "$IMAGE_URL" -o /workspace/input/source.png
wget -q -O /workspace/input/audio_raw "$AUDIO_URL" || curl -sL "$AUDIO_URL" -o /workspace/input/audio_raw
ffmpeg -y -i /workspace/input/audio_raw -ar 16000 -ac 1 /workspace/input/audio.wav > /dev/null 2>&1 || \
    mv /workspace/input/audio_raw /workspace/input/audio.wav

log_info "✅ Fichiers OK"

# =============================================================================
# ÉTAPE 3: PRÉPARER INPUT FILE
# =============================================================================
log_step "Préparation inférence..."

cat > /workspace/input/input.txt << EOF
A person talking naturally@@/workspace/input/source.png@@/workspace/input/audio.wav
EOF

log_info "Input: $(cat /workspace/input/input.txt)"

# =============================================================================
# ÉTAPE 4: LANCER INFÉRENCE
# =============================================================================
log_step "Lancement génération vidéo..."

bash scripts/inference_long_batch.sh /workspace/input/input.txt /workspace/output 2>&1 | tee /workspace/hallo3_inference.log

# =============================================================================
# ÉTAPE 5: RÉCUPÉRER RÉSULTAT ET ENVOYER
# =============================================================================
log_step "Recherche vidéo générée..."

VIDEO_FILE=$(find /workspace/output -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "$VIDEO_FILE" ] && [ -f "$VIDEO_FILE" ]; then
    log_info "✅ Vidéo: $VIDEO_FILE"
    VIDEO_SIZE=$(stat -c%s "$VIDEO_FILE")
    log_info "Taille: $(numfmt --to=iec $VIDEO_SIZE)"
    
    if [ -n "$WEBHOOK_URL" ]; then
        log_step "Envoi vidéo au webhook..."
        
        curl -s -X POST "$WEBHOOK_URL" \
            -F "status=success" \
            -F "job_id=$JOB_ID" \
            -F "filename=$(basename $VIDEO_FILE)" \
            -F "size=$VIDEO_SIZE" \
            -F "video=@$VIDEO_FILE;type=video/mp4"
        
        log_info "✅ Webhook envoyé"
    fi
    
    # Signal à l'orchestrateur
    if [ -n "$WEBHOOK_ORCHESTRATOR" ]; then
        log_step "Signal fin de job à l'orchestrateur..."
        INSTANCE_ID=$(echo $CONTAINER_ID | sed 's/C\.//')
        curl -s -X POST "$WEBHOOK_ORCHESTRATOR" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"job_complete\",\"job_id\":\"$JOB_ID\",\"instance_id\":\"$INSTANCE_ID\",\"success\":true}"
        log_info "✅ Orchestrateur notifié"
    fi
else
    log_error "Aucune vidéo générée!"
    tail -20 /workspace/hallo3_inference.log
    
    if [ -n "$WEBHOOK_URL" ]; then
        ERROR_LOG=$(tail -10 /workspace/hallo3_inference.log | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 500)
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"error\",\"job_id\":\"$JOB_ID\",\"message\":\"No video generated\",\"log\":\"$ERROR_LOG\"}"
    fi
    
    # Signal erreur à l'orchestrateur
    if [ -n "$WEBHOOK_ORCHESTRATOR" ]; then
        log_step "Signal erreur à l'orchestrateur..."
        INSTANCE_ID=$(echo $CONTAINER_ID | sed 's/C\.//')
        curl -s -X POST "$WEBHOOK_ORCHESTRATOR" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"job_complete\",\"job_id\":\"$JOB_ID\",\"instance_id\":\"$INSTANCE_ID\",\"success\":false}"
        log_info "✅ Orchestrateur notifié (erreur)"
    fi
    exit 1
fi

log_info "🎉 Terminé!"
