#!/bin/bash
# GPT-SoVITS Fine-tuning Script for Vast.ai
# Usage: bash gpt_sovits_finetune.sh <WEBHOOK_URL> <PROJECT_NAME>

WEBHOOK_URL="${1:-}"
PROJECT_NAME="${2:-voice_model}"

# Google Drive file ID
GDRIVE_FILE_ID="1u0uwukYeufwmac9qyCHTxgtH0ejmX35T"

echo "============================================"
echo "GPT-SoVITS Fine-tuning Script"
echo "============================================"
echo "Project: $PROJECT_NAME"
echo "Audio: Google Drive ID $GDRIVE_FILE_ID"
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
pip install -q gdown 2>/dev/null
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
    git pull --quiet || true
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
pip install -q --upgrade pip 2>/dev/null

# Install requirements with retry
for attempt in 1 2 3; do
    echo "Attempt $attempt/3..."
    pip install -q -r requirements.txt 2>/dev/null && break
    sleep 5
done

# Additional dependencies
pip install -q funasr modelscope faster-whisper gdown 2>/dev/null

echo "✓ Python dependencies installed"

# ============================================
# STEP 4: Download Pre-trained Models
# ============================================
echo ""
echo "[4/8] Downloading pre-trained models..."

cd /workspace/GPT-SoVITS

# Create directories
mkdir -p GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large
mkdir -p GPT_SoVITS/pretrained_models/chinese-hubert-base
mkdir -p GPT_SoVITS/pretrained_models/gsv-v2final-pretrained

echo "Downloading GPT model..."
if [ ! -f "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s1bert25hz-5kh-longer-epoch=12-step=369668.ckpt" ]; then
    wget -q --show-progress -O "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s1bert25hz-5kh-longer-epoch=12-step=369668.ckpt" \
        "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/gsv-v2final-pretrained/s1bert25hz-5kh-longer-epoch%3D12-step%3D369668.ckpt" || true
fi
echo "✓ GPT model"

echo "Downloading SoVITS model..."
if [ ! -f "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth" ]; then
    wget -q --show-progress -O "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth" \
        "https://huggingface.co/lj1995/GPT-SoVITS/resolve/main/gsv-v2final-pretrained/s2G2333k.pth" || true
fi
echo "✓ SoVITS model"

echo "Downloading Chinese BERT..."
cd GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large
if [ ! -f "pytorch_model.bin" ]; then
    wget -q --show-progress "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/pytorch_model.bin" || true
    wget -q "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/config.json" || true
    wget -q "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/tokenizer.json" || true
    wget -q "https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/vocab.txt" || true
fi
echo "✓ Chinese BERT"

echo "Downloading Chinese HuBERT..."
cd ../chinese-hubert-base
if [ ! -f "pytorch_model.bin" ]; then
    wget -q --show-progress "https://huggingface.co/TencentGameMate/chinese-hubert-base/resolve/main/pytorch_model.bin" || true
    wget -q "https://huggingface.co/TencentGameMate/chinese-hubert-base/resolve/main/config.json" || true
    wget -q "https://huggingface.co/TencentGameMate/chinese-hubert-base/resolve/main/preprocessor_config.json" || true
fi
echo "✓ Chinese HuBERT"

cd /workspace/GPT-SoVITS
echo "✓ Pre-trained models downloaded"

# ============================================
# STEP 5: Download Audio File from Google Drive
# ============================================
echo ""
echo "[5/8] Downloading audio file from Google Drive..."
mkdir -p /workspace/GPT-SoVITS/raw_audio
cd /workspace/GPT-SoVITS/raw_audio

echo "Downloading file ID: $GDRIVE_FILE_ID"

# Method 1: gdown (most reliable)
gdown "https://drive.google.com/uc?id=${GDRIVE_FILE_ID}" -O parole.mp3 || {
    echo "gdown failed, trying curl method..."
    
    # Method 2: curl with confirmation bypass
    curl -L "https://drive.google.com/uc?export=download&id=${GDRIVE_FILE_ID}&confirm=t" -o parole.mp3 || {
        echo "curl failed, trying wget method..."
        
        # Method 3: wget
        wget --no-check-certificate "https://drive.google.com/uc?export=download&id=${GDRIVE_FILE_ID}&confirm=t" -O parole.mp3
    }
}

# Check file size
FILE_SIZE=$(stat -c%s "parole.mp3" 2>/dev/null || stat -f%z "parole.mp3" 2>/dev/null || echo "0")
echo "File size: $FILE_SIZE bytes ($(echo "scale=2; $FILE_SIZE/1024/1024" | bc) MB)"

if [ "$FILE_SIZE" -lt 1000000 ]; then
    echo "⚠️ File seems too small, might be a download error page"
    echo "First 500 bytes of file:"
    head -c 500 parole.mp3
    echo ""
    echo "Trying alternative download method with gdown..."
    pip install -q --upgrade gdown
    gdown --fuzzy "https://drive.google.com/file/d/${GDRIVE_FILE_ID}/view" -O parole.mp3
    FILE_SIZE=$(stat -c%s "parole.mp3" 2>/dev/null || echo "0")
    echo "New file size: $FILE_SIZE bytes"
fi

if [ "$FILE_SIZE" -lt 1000000 ]; then
    echo "❌ Audio file download failed! Size: $FILE_SIZE bytes"
    exit 1
fi

# Convert to WAV 16kHz mono (optimal for GPT-SoVITS)
echo "Converting to WAV..."
ffmpeg -y -i parole.mp3 -ar 16000 -ac 1 -c:a pcm_s16le parole.wav 2>/dev/null || {
    echo "❌ FFmpeg conversion failed!"
    exit 1
}

# Get audio duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 parole.wav 2>/dev/null | cut -d. -f1)
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
export PROJECT_NAME

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

echo "✓ Audio preprocessing complete"

# ============================================
# STEP 7: ASR Transcription (Whisper)
# ============================================
echo ""
echo "[7/8] Transcribing audio with Whisper..."

python3 << 'PYTHON_ASR'
import os
import glob

project = os.environ.get('PROJECT_NAME', 'voice_model')
wavs_dir = f"data/{project}/wavs"
output_file = f"data/{project}/transcription.list"

print("Loading Whisper model...")
try:
    from faster_whisper import WhisperModel
    model = WhisperModel("large-v3", device="cuda", compute_type="float16")
    print("Using GPU (large-v3)")
except Exception as e:
    print(f"GPU failed: {e}")
    print("Trying CPU mode with medium model...")
    from faster_whisper import WhisperModel
    model = WhisperModel("medium", device="cpu", compute_type="int8")

wav_files = sorted(glob.glob(f"{wavs_dir}/*.wav"))
print(f"Transcribing {len(wav_files)} audio files...")

transcriptions = []
for i, wav_file in enumerate(wav_files):
    try:
        segments, info = model.transcribe(wav_file, language="fr", beam_size=5)
        text = " ".join([seg.text.strip() for seg in segments])
        
        # Format: path|speaker|language|text
        basename = os.path.basename(wav_file)
        line = f"{wavs_dir}/{basename}|{project}|FR|{text}"
        transcriptions.append(line)
        print(f"  [{i+1}/{len(wav_files)}] {basename}: {text[:60]}...")
    except Exception as e:
        print(f"  Error transcribing {wav_file}: {e}")

# Write transcription list
with open(output_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(transcriptions))

print(f"✓ Transcriptions saved to {output_file}")
print(f"Total: {len(transcriptions)} transcriptions")
PYTHON_ASR

echo "✓ Transcription complete"

# ============================================
# STEP 8: Package Dataset
# ============================================
echo ""
echo "[8/8] Packaging dataset..."
cd /workspace/GPT-SoVITS

# Show what we have
echo "Dataset contents:"
ls -la "data/${PROJECT_NAME}/wavs/" | head -20
echo ""
echo "Transcription preview:"
head -5 "data/${PROJECT_NAME}/transcription.list" || echo "No transcription file"

OUTPUT_DIR="/workspace/GPT-SoVITS/output/${PROJECT_NAME}"
mkdir -p "$OUTPUT_DIR"

# Copy dataset
cp -r "data/${PROJECT_NAME}" "$OUTPUT_DIR/dataset"
cp /workspace/GPT-SoVITS/raw_audio/parole.mp3 "$OUTPUT_DIR/"
cp /workspace/GPT-SoVITS/raw_audio/parole.wav "$OUTPUT_DIR/"

# Create info file
cat > "$OUTPUT_DIR/model_info.json" << EOF
{
    "project": "${PROJECT_NAME}",
    "created": "$(date -Iseconds)",
    "instance_id": "${INSTANCE_ID}",
    "audio_source": "gdrive:${GDRIVE_FILE_ID}",
    "audio_duration_seconds": ${DURATION:-0},
    "language": "fr",
    "status": "dataset_prepared"
}
EOF

# Create zip archive
cd /workspace/GPT-SoVITS/output
zip -qr "${PROJECT_NAME}_dataset.zip" "${PROJECT_NAME}/"
DATASET_ZIP="/workspace/GPT-SoVITS/output/${PROJECT_NAME}_dataset.zip"

echo "✓ Dataset packaged: $DATASET_ZIP"
ls -lh "$DATASET_ZIP"

# ============================================
# Send Webhook Notification
# ============================================
if [ -n "$WEBHOOK_URL" ]; then
    echo ""
    echo "Sending webhook notification..."
    
    curl -s -X POST "$WEBHOOK_URL" \
        -F "instance_id=${INSTANCE_ID}" \
        -F "project=${PROJECT_NAME}" \
        -F "status=dataset_ready" \
        -F "audio_duration=${DURATION:-0}" \
        -F "file=@${DATASET_ZIP}" \
        && echo "✓ Webhook sent successfully" \
        || echo "⚠️ Webhook failed"
fi

# ============================================
# Summary
# ============================================
echo ""
echo "============================================"
echo "DATASET PREPARATION COMPLETE"
echo "============================================"
echo "Project: ${PROJECT_NAME}"
echo "Instance: ${INSTANCE_ID}"
echo "Audio Duration: ${DURATION:-unknown}s"
echo "Segments: $(ls -1 data/${PROJECT_NAME}/wavs/*.wav 2>/dev/null | wc -l)"
echo ""
echo "Dataset archive: ${DATASET_ZIP}"
echo "============================================"
