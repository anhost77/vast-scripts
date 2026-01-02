#!/bin/bash
# =============================================================================
# MERGE INIT - Initialisation instance pour fusion vidéos
# =============================================================================

WEBHOOK_READY="$1"

echo "=========================================="
echo "  Merge Videos - Initialisation"
echo "=========================================="

# Installer dépendances
apt-get update -qq && apt-get install -y -qq ffmpeg git wget curl

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

# Envoyer webhook ready
if [ -n "$WEBHOOK_READY" ]; then
    curl -s -X POST "$WEBHOOK_READY" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"ready\",\"type\":\"merge\"}"
    echo "✅ Webhook envoyé"
fi

echo "🎉 Instance prête pour fusion!"
