#!/bin/bash
# GPT-SoVITS Init Script for Vast.ai
# Called on instance startup via onstart
# Usage: bash gpt_sovits_init.sh <WEBHOOK_URL> <PROJECT_NAME>

WEBHOOK_URL="${1:-}"
PROJECT_NAME="${2:-voice_model}"

echo "============================================"
echo "GPT-SoVITS Instance Initialization"
echo "============================================"
echo "Webhook: $WEBHOOK_URL"
echo "Project: $PROJECT_NAME"
echo "============================================"

# Get instance ID
if [ -f ~/.vast_containerlabel ]; then
    INSTANCE_ID=$(cat ~/.vast_containerlabel | sed 's/C\.//')
else
    INSTANCE_ID="unknown"
fi
echo "Instance ID: $INSTANCE_ID"

cd /workspace

# Download and run fine-tuning script
echo "Downloading fine-tuning script..."
wget -qO gpt_sovits_finetune.sh "https://raw.githubusercontent.com/anhost77/vast-scripts/main/gpt_sovits_finetune.sh?$(date +%s)"
chmod +x gpt_sovits_finetune.sh

# Send "started" webhook
if [ -n "$WEBHOOK_URL" ]; then
    echo "Sending startup notification..."
    curl -s -X POST "${WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"instance_id\":\"${INSTANCE_ID}\",\"project\":\"${PROJECT_NAME}\",\"status\":\"started\"}" \
        || echo "⚠️ Startup webhook failed"
fi

# Run fine-tuning
echo "Starting fine-tuning process..."
bash gpt_sovits_finetune.sh "$WEBHOOK_URL" "$PROJECT_NAME"

echo "============================================"
echo "Process complete!"
echo "============================================"
