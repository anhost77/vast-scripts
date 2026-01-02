#!/bin/bash
# =============================================================================
# MERGE INIT - Initialisation instance pour fusion vidéos
# =============================================================================

WEBHOOK_READY="$1"
PROJECT="$2"

echo "=========================================="
echo "  Merge Videos - Initialisation"
echo "  Projet: $PROJECT"
echo "=========================================="

# Installer dépendances
apt-get update -qq && apt-get install -y -qq ffmpeg git wget curl bc

# Installer RIFE
cd /workspace
if [ ! -d "Practical-RIFE" ]; then
    git clone https://github.com/hzwer/Practical-RIFE.git
    cd Practical-RIFE
    pip install -q -r requirements.txt
    
    # Télécharger le modèle
    mkdir -p train_log
    wget -q -O train_log/flownet.pkl "https://github.com/hzwer/Practical-RIFE/releases/download/v4.6/flownet.pkl"
fi

echo "✅ RIFE installé"

# Créer dossiers
mkdir -p /workspace/input /workspace/output

# Sauvegarder le projet pour merge_videos.sh
echo "$PROJECT" > /workspace/project_name.txt

# Récupérer instance_id
INSTANCE_ID=$(echo $CONTAINER_ID | sed 's/C\.//')

# Envoyer webhook ready
if [ -n "$WEBHOOK_READY" ]; then
    curl -s -X POST "$WEBHOOK_READY" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"ready\",\"instance_id\":\"$INSTANCE_ID\",\"project\":\"$PROJECT\"}"
    echo "✅ Webhook envoyé"
fi

echo "🎉 Instance prête pour fusion!"
