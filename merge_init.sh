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
fi

cd Practical-RIFE

# Retry pip install
for i in 1 2 3; do
    pip install -q -r requirements.txt && break
    echo "Retry pip install ($i/3)..."
    sleep 5
done

# Télécharger le modèle
mkdir -p train_log
if [ ! -f "train_log/flownet.pkl" ]; then
    wget -q -O train_log/flownet.pkl "https://github.com/hzwer/Practical-RIFE/releases/download/v4.6/flownet.pkl" || \
    wget -q -O train_log/flownet.pkl "https://github.com/hzwer/Practical-RIFE/releases/download/v4.5/flownet.pkl"
fi

# Vérifier installation
if [ -f "train_log/flownet.pkl" ]; then
    echo "✅ RIFE installé"
else
    echo "❌ RIFE installation échouée"
fi

# Créer dossiers
mkdir -p /workspace/input /workspace/output

# Sauvegarder le projet
echo "$PROJECT" > /workspace/project_name.txt

# Récupérer instance_id depuis variable d'environnement Vast.ai
# Récupérer instance_id depuis le hostname (C.29435473)
# Récupérer instance_id depuis le fichier Vast.ai
INSTANCE_ID=$(cat ~/.vast_containerlabel | sed 's/C\.//')
echo "Instance ID: $INSTANCE_ID"

# Envoyer webhook ready
if [ -n "$WEBHOOK_READY" ]; then
    curl -s -X POST "$WEBHOOK_READY" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"ready\",\"instance_id\":\"$INSTANCE_ID\",\"project\":\"$PROJECT\"}"
    echo "✅ Webhook envoyé"
fi

echo "🎉 Instance prête pour fusion!"
