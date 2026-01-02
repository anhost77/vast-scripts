#!/bin/bash
# GPT-SoVITS Fine-tuning Script for Vast.ai
# Usage: bash gpt_sovits_finetune.sh <WEBHOOK_URL> <PROJECT_NAME> <GDRIVE_FOLDER_ID>

set -e

WEBHOOK_URL="${1:-}"
PROJECT_NAME="${2:-voice_model}"
GDRIVE_FOLDER_ID="${3:-}"
AUDIO_URL="https://raw.githubusercontent.com/anhost77/vast-scripts/main/parole.mp3"

echo "============================================"
echo "GPT-SoVITS Fine-tuning Script"
echo "============================================"
echo "Project: $PROJECT_NAME"
echo "Audio URL: $AUDIO_URL"
echo "Webhook: $WEBHOOK_URL"
echo "============================================"

# Get instance ID
if [ -f ~/.vast_containerlabel ]; then
    INSTANCE_ID=$(cat ~/.vast_containerlabel | sed 's/C\.//')
else
    INSTANCE_ID="unknown"
fi
echo "Instance ID: $INSTANCE_ID"

# ============================================
# STEP 1: System Dependencies
# ============================================
echo ""
echo "[1/8] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq ffmpeg git wget curl unzip sox libsox-fmt-all > /dev/null 2>&1
echo "✓ System dependencies installed"

# ============================================
# STEP 2: Clone GPT-SoVITS
# ============================================
echo ""
echo "[2/8] Cloning GPT-SoVITS..."
cd /workspace

if [ -d "GPT-SoVITS" ]; then
    echo "GPT-SoVITS already exists, updating..."
    cd GPT-SoVITS
    git pull --quiet
else
    git clone --depth 1 https://github.com/RVC-Boss/GPT-SoVITS.git
    cd GPT-SoVITS
fi
echo "✓ GPT-SoVITS cloned"

# ============================================
# STEP 3: Python Dependencies
# ============================================
echo ""
echo "[3/8] Installing Python dependencies..."
pip install -q --upgrade pip

# Install requirements with retry
for attempt in 1 2 3; do
    echo "Attempt $attempt/3..."
    pip install -q -r requirements.txt && break
    sleep 5
done

# Additional dependencies
pip install -q funasr modelscope gradio==3.50.2 faster-whisper

echo "✓ Python dependencies installed"

# ============================================
# STEP 4: Download Pre-trained Models
# ============================================
echo ""
echo "[4/8] Downloading pre-trained models..."

# Create directories
mkdir -p GPT_SoVITS/pretrained_models
mkdir -p tools/uvr5/uvr5_weights
mkdir -p tools/asr/models

# Download GPT-SoVITS pretrained models from Hugging Face
echo "Downloading GPT-SoVITS base models..."
cd GPT_SoVITS/pretrained_models

# GPT model
if [ ! -f "s1bert25hz-2kh-longer-epoch=68e-step=50232.ckpt" ]; then
    wget -q --show-progress "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/s1bert25hz-2kh-longer-epoch%3D68e-step%3D50232.ckpt" -O "s1bert25hz-2kh-longer-epoch=68e-step=50232.ckpt"
fi

# SoVITS model
if [ ! -f "s2G488k.pth" ]; then
    wget -q --show-progress "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/s2G488k.pth"
fi

# Chinese BERT
mkdir -p chinese-roberta-wwm-ext-large
if [ ! -f "chinese-roberta-wwm-ext-large/pytorch_model.bin" ]; then
    echo "Downloading Chinese BERT..."
    wget -q --show-progress "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/pytorch_model.bin" -O "chinese-roberta-wwm-ext-large/pytorch_model.bin"
    wget -q "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/config.json" -O "chinese-roberta-wwm-ext-large/config.json"
    wget -q "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/tokenizer.json" -O "chinese-roberta-wwm-ext-large/tokenizer.json"
fi

# Chinese HuBERT
mkdir -p chinese-hubert-base
if [ ! -f "chinese-hubert-base/pytorch_model.bin" ]; then
    echo "Downloading Chinese HuBERT..."
    wget -q --show-progress "https://huggingface.co/TencentGameMate/chinese-hubert-base/resolve/main/pytorch_model.bin" -O "chinese-hubert-base/pytorch_model.bin"
    wget -q "https://huggingface.co/TencentGameMate/chinese-hubert-base/resolve/main/config.json" -O "chinese-hubert-base/config.json"
fi

cd /workspace/GPT-SoVITS
echo "✓ Pre-trained models downloaded"

# ============================================
# STEP 5: Download Audio File
# ============================================
echo ""
echo "[5/8] Downloading audio file..."
mkdir -p /workspace/GPT-SoVITS/raw_audio
cd /workspace/GPT-SoVITS/raw_audio

wget -q --show-progress "$AUDIO_URL" -O "parole.mp3"

# Convert to WAV 16kHz mono (optimal for GPT-SoVITS)
ffmpeg -y -i parole.mp3 -ar 16000 -ac 1 -c:a pcm_s16le parole.wav 2>/dev/null

# Get audio duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 parole.wav | cut -d. -f1)
echo "✓ Audio downloaded and converted (duration: ${DURATION}s)"

# ============================================
# STEP 6: Audio Preprocessing
# ============================================
echo ""
echo "[6/8] Preprocessing audio..."
cd /workspace/GPT-SoVITS

# Create dataset directories
mkdir -p "data/${PROJECT_NAME}/raw"
mkdir -p "data/${PROJECT_NAME}/wavs"
mkdir -p "output/${PROJECT_NAME}"

# Copy audio
cp /workspace/GPT-SoVITS/raw_audio/parole.wav "data/${PROJECT_NAME}/raw/"

# Split audio into segments (10-15 seconds each for optimal training)
echo "Splitting audio into segments..."
python3 << 'PYTHON_SPLIT'
import os
import subprocess
import math

project = os.environ.get('PROJECT_NAME', 'voice_model')
input_file = f"data/{project}/raw/parole.wav"
output_dir = f"data/{project}/wavs"

# Get duration
result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', input_file], capture_output=True, text=True)
duration = float(result.stdout.strip())

# Split into 10-second segments
segment_duration = 10
num_segments = math.ceil(duration / segment_duration)

print(f"Splitting {duration:.1f}s audio into {num_segments} segments...")

for i in range(num_segments):
    start = i * segment_duration
    output_file = f"{output_dir}/segment_{i:04d}.wav"
    subprocess.run([
        'ffmpeg', '-y', '-i', input_file,
        '-ss', str(start), '-t', str(segment_duration),
        '-ar', '16000', '-ac', '1',
        output_file
    ], capture_output=True)
    
print(f"✓ Created {num_segments} audio segments")
PYTHON_SPLIT

export PROJECT_NAME
echo "✓ Audio preprocessing complete"

# ============================================
# STEP 7: ASR Transcription (Whisper)
# ============================================
echo ""
echo "[7/8] Transcribing audio with Whisper..."

python3 << 'PYTHON_ASR'
import os
import glob
from faster_whisper import WhisperModel

project = os.environ.get('PROJECT_NAME', 'voice_model')
wavs_dir = f"data/{project}/wavs"
output_file = f"data/{project}/transcription.list"

print("Loading Whisper model (large-v3)...")
model = WhisperModel("large-v3", device="cuda", compute_type="float16")

wav_files = sorted(glob.glob(f"{wavs_dir}/*.wav"))
print(f"Transcribing {len(wav_files)} audio files...")

transcriptions = []
for wav_file in wav_files:
    segments, info = model.transcribe(wav_file, language="fr", beam_size=5)
    text = " ".join([seg.text.strip() for seg in segments])
    
    # Format: path|speaker|language|text
    basename = os.path.basename(wav_file)
    line = f"{wavs_dir}/{basename}|{project}|FR|{text}"
    transcriptions.append(line)
    print(f"  {basename}: {text[:50]}...")

# Write transcription list
with open(output_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(transcriptions))

print(f"✓ Transcriptions saved to {output_file}")
PYTHON_ASR

export PROJECT_NAME
echo "✓ Transcription complete"

# ============================================
# STEP 8: Fine-tuning
# ============================================
echo ""
echo "[8/8] Starting fine-tuning..."
cd /workspace/GPT-SoVITS

# Create training config
cat > "data/${PROJECT_NAME}/config.json" << EOF
{
    "train_data": "data/${PROJECT_NAME}/transcription.list",
    "exp_name": "${PROJECT_NAME}",
    "epochs_gpt": 10,
    "epochs_sovits": 10,
    "batch_size": 4,
    "save_every_epoch": 5
}
EOF

# Run GPT training
echo "Training GPT model..."
python3 GPT_SoVITS/s1_train.py \
    --config_file "data/${PROJECT_NAME}/config.json" \
    --exp_name "${PROJECT_NAME}" \
    --train_data "data/${PROJECT_NAME}/transcription.list" \
    --epochs 10 \
    --batch_size 4 \
    2>&1 | tail -20

# Run SoVITS training
echo "Training SoVITS model..."
python3 GPT_SoVITS/s2_train.py \
    --config_file "data/${PROJECT_NAME}/config.json" \
    --exp_name "${PROJECT_NAME}" \
    --train_data "data/${PROJECT_NAME}/transcription.list" \
    --epochs 10 \
    --batch_size 4 \
    2>&1 | tail -20

echo "✓ Fine-tuning complete"

# ============================================
# Package Models
# ============================================
echo ""
echo "Packaging trained models..."

OUTPUT_DIR="/workspace/GPT-SoVITS/output/${PROJECT_NAME}"
mkdir -p "$OUTPUT_DIR"

# Find and copy trained models
find GPT_weights*/ -name "*${PROJECT_NAME}*" -exec cp {} "$OUTPUT_DIR/" \; 2>/dev/null || true
find SoVITS_weights*/ -name "*${PROJECT_NAME}*" -exec cp {} "$OUTPUT_DIR/" \; 2>/dev/null || true

# Create info file
cat > "$OUTPUT_DIR/model_info.json" << EOF
{
    "project": "${PROJECT_NAME}",
    "created": "$(date -Iseconds)",
    "instance_id": "${INSTANCE_ID}",
    "audio_source": "${AUDIO_URL}",
    "audio_duration_seconds": ${DURATION:-0},
    "language": "fr"
}
EOF

# Create zip archive
cd /workspace/GPT-SoVITS/output
zip -r "${PROJECT_NAME}_model.zip" "${PROJECT_NAME}/"
MODEL_ZIP="/workspace/GPT-SoVITS/output/${PROJECT_NAME}_model.zip"

echo "✓ Model packaged: $MODEL_ZIP"

# ============================================
# Upload to Google Drive (if configured)
# ============================================
if [ -n "$GDRIVE_FOLDER_ID" ]; then
    echo ""
    echo "Uploading to Google Drive..."
    
    # Install rclone if needed
    if ! command -v rclone &> /dev/null; then
        curl -s https://rclone.org/install.sh | bash
    fi
    
    # TODO: Configure rclone with service account
    echo "⚠️ Google Drive upload requires rclone configuration"
fi

# ============================================
# Send Webhook Notification
# ============================================
if [ -n "$WEBHOOK_URL" ]; then
    echo ""
    echo "Sending webhook notification..."
    
    # Send model file via multipart form
    curl -s -X POST "$WEBHOOK_URL" \
        -F "instance_id=${INSTANCE_ID}" \
        -F "project=${PROJECT_NAME}" \
        -F "status=complete" \
        -F "audio_duration=${DURATION:-0}" \
        -F "model=@${MODEL_ZIP}" \
        && echo "✓ Webhook sent successfully" \
        || echo "⚠️ Webhook failed"
fi

# ============================================
# Summary
# ============================================
echo ""
echo "============================================"
echo "FINE-TUNING COMPLETE"
echo "============================================"
echo "Project: ${PROJECT_NAME}"
echo "Instance: ${INSTANCE_ID}"
echo "Audio Duration: ${DURATION:-unknown}s"
echo ""
echo "Output files:"
ls -lh "$OUTPUT_DIR/" 2>/dev/null || echo "No output files found"
echo ""
echo "Model archive: ${MODEL_ZIP}"
echo "============================================"

# Keep container alive for manual inspection (optional)
# tail -f /dev/null
