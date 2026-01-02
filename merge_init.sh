#!/bin/bash
# =============================================================================
# MERGE INIT - Initialisation instance pour fusion vidéos + upscale
# =============================================================================
WEBHOOK_READY="$1"
PROJECT="$2"

echo "=========================================="
echo "  Merge Videos - Initialisation"
echo "  Projet: $PROJECT"
echo "=========================================="

# Installer dépendances système
apt-get update -qq && apt-get install -y -qq ffmpeg git wget curl bc

# =============================================================================
# RIFE (transitions)
# =============================================================================
echo "[1/3] Installation RIFE..."
cd /workspace
if [ ! -d "Practical-RIFE" ]; then
    git clone https://github.com/hzwer/Practical-RIFE.git
fi
cd Practical-RIFE

for i in 1 2 3; do
    pip install -q -r requirements.txt && break
    echo "Retry pip install RIFE ($i/3)..."
    sleep 5
done

mkdir -p train_log
if [ ! -f "train_log/flownet.pkl" ]; then
    wget -q -O train_log/flownet.pkl "https://github.com/hzwer/Practical-RIFE/releases/download/v4.6/flownet.pkl" || \
    wget -q -O train_log/flownet.pkl "https://github.com/hzwer/Practical-RIFE/releases/download/v4.5/flownet.pkl"
fi

if [ -f "train_log/flownet.pkl" ]; then
    echo "✅ RIFE installé"
else
    echo "❌ RIFE installation échouée"
fi

# =============================================================================
# Real-ESRGAN (upscale)
# =============================================================================
echo "[2/3] Installation Real-ESRGAN..."
cd /workspace

# Patch basicsr pour compatibilité torchvision
BASICSR_FILE="/usr/local/lib/python3.10/dist-packages/basicsr/data/degradations.py"
if [ -f "$BASICSR_FILE" ]; then
    sed -i 's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/' "$BASICSR_FILE" 2>/dev/null || true
fi

# Installer realesrgan
pip install -q realesrgan --no-deps 2>/dev/null || pip3 install -q realesrgan --no-deps

# Télécharger le modèle
mkdir -p /workspace/Real-ESRGAN/weights
if [ ! -f "/workspace/Real-ESRGAN/weights/RealESRGAN_x4plus.pth" ]; then
    wget -q -O /workspace/Real-ESRGAN/weights/RealESRGAN_x4plus.pth "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
fi

if [ -f "/workspace/Real-ESRGAN/weights/RealESRGAN_x4plus.pth" ]; then
    echo "✅ Real-ESRGAN installé"
else
    echo "❌ Real-ESRGAN installation échouée"
fi

# =============================================================================
# Finalisation
# =============================================================================
echo "[3/3] Finalisation..."
mkdir -p /workspace/input /workspace/output
echo "$PROJECT" > /workspace/project_name.txt

# Récupérer instance_id
INSTANCE_ID=$(cat ~/.vast_containerlabel | sed 's/C\.//')
echo "Instance ID: $INSTANCE_ID"

# Envoyer webhook ready
if [ -n "$WEBHOOK_READY" ]; then
    curl -s -X POST "$WEBHOOK_READY" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"ready\",\"instance_id\":\"$INSTANCE_ID\",\"project\":\"$PROJECT\"}"
    echo "✅ Webhook envoyé"
fi

echo "🎉 Instance prête pour fusion + upscale!"
