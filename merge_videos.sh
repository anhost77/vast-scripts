#!/bin/bash
# =============================================================================
# MERGE VIDEOS - Fusion avec transitions RIFE + Upscale Real-ESRGAN + Upload
# =============================================================================

PROJECT_NAME="$1"
VIDEO_URLS="$2"
WEBHOOK_URL="$3"
INSTANCE_ID="$4"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}[STEP]${NC} $1"; }

echo "=========================================="
echo "  Merge Videos - Projet: $PROJECT_NAME"
echo "=========================================="

if [ -z "$PROJECT_NAME" ] || [ -z "$VIDEO_URLS" ]; then
    log_error "Usage: bash merge_videos.sh <project_name> <video_urls> [webhook_url] [instance_id]"
    exit 1
fi

WORK_DIR="/workspace/merge_work"
RIFE_DIR="/workspace/Practical-RIFE"
ESRGAN_DIR="/workspace/Real-ESRGAN"
OUTPUT_DIR="/workspace/output"
OUTPUT_FILE="$OUTPUT_DIR/${PROJECT_NAME}_final.mp4"
UPSCALED_FILE="$OUTPUT_DIR/${PROJECT_NAME}_upscaled.mp4"
FPS=25

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/videos" "$WORK_DIR/transitions" "$WORK_DIR/final" "$WORK_DIR/frames" "$WORK_DIR/frames_up"
mkdir -p "$OUTPUT_DIR"

# =============================================================================
# ÉTAPE 1: INSTALLER RIFE
# =============================================================================
log_step "Installation RIFE..."

if [ ! -d "$RIFE_DIR" ]; then
    cd /workspace
    git clone https://github.com/hzwer/Practical-RIFE.git
    cd Practical-RIFE
    pip install -q -r requirements.txt --break-system-packages 2>/dev/null || pip install -q -r requirements.txt
    mkdir -p train_log
    wget -q -O train_log/flownet.pkl "https://github.com/hzwer/Practical-RIFE/releases/download/v4.6/flownet.pkl" || true
    log_info "✅ RIFE installé"
else
    log_info "✅ RIFE déjà présent"
fi

# =============================================================================
# ÉTAPE 2: INSTALLER Real-ESRGAN
# =============================================================================
log_step "Installation Real-ESRGAN..."

if [ ! -d "$ESRGAN_DIR" ]; then
    cd /workspace
    git clone https://github.com/xinntao/Real-ESRGAN.git
    cd Real-ESRGAN
    pip install -q basicsr gfpgan --break-system-packages 2>/dev/null || pip install -q basicsr gfpgan
    pip install -q -r requirements.txt --break-system-packages 2>/dev/null || pip install -q -r requirements.txt
    python setup.py develop --quiet 2>/dev/null || python setup.py develop
    
    # Télécharger le modèle vidéo
    wget -q -O weights/realesr-animevideov3.pth "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
    log_info "✅ Real-ESRGAN installé"
else
    log_info "✅ Real-ESRGAN déjà présent"
fi

# =============================================================================
# ÉTAPE 3: TÉLÉCHARGER LES VIDÉOS
# =============================================================================
log_step "Téléchargement des vidéos..."

IFS=',' read -ra URLS <<< "$VIDEO_URLS"
NUM_VIDEOS=${#URLS[@]}

log_info "$NUM_VIDEOS vidéos à télécharger"

i=0
for url in "${URLS[@]}"; do
    idx=$(printf "%03d" $i)
    output_file="$WORK_DIR/videos/video_${idx}.mp4"
    
    if [[ "$url" == *"drive.google.com"* ]]; then
        file_id=$(echo "$url" | grep -oP '(?<=/d/)[^/]+|(?<=id=)[^&]+' | head -1)
        download_url="https://drive.google.com/uc?export=download&id=$file_id"
    else
        download_url="$url"
    fi
    
    log_info "  [$((i+1))/$NUM_VIDEOS] Téléchargement..."
    wget -q -O "$output_file" "$download_url" || curl -sL "$download_url" -o "$output_file"
    
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        log_info "  ✅ video_${idx}.mp4"
    else
        log_error "  ❌ Échec téléchargement: $url"
    fi
    
    i=$((i+1))
done

NUM_VIDEOS=$(ls -1 "$WORK_DIR/videos"/*.mp4 2>/dev/null | wc -l)
log_info "✅ $NUM_VIDEOS vidéos téléchargées"

if [ "$NUM_VIDEOS" -eq 0 ]; then
    log_error "Aucune vidéo téléchargée!"
    exit 1
fi

# =============================================================================
# ÉTAPE 4: GÉNÉRER LES TRANSITIONS RIFE
# =============================================================================
if [ "$NUM_VIDEOS" -gt 1 ]; then
    log_step "Génération des transitions RIFE..."
    
    cd "$RIFE_DIR"
    mkdir -p output
    
    for i in $(seq 0 $((NUM_VIDEOS-2))); do
        curr=$(printf "%03d" $i)
        next=$(printf "%03d" $((i+1)))
        
        log_info "Transition $curr → $next..."
        
        ffmpeg -y -sseof -0.04 -i "$WORK_DIR/videos/video_${curr}.mp4" \
            -frames:v 1 -update 1 "$WORK_DIR/transitions/frame_${curr}_last.png" 2>/dev/null
        
        ffmpeg -y -ss 0 -i "$WORK_DIR/videos/video_${next}.mp4" \
            -frames:v 1 -update 1 "$WORK_DIR/transitions/frame_${next}_first.png" 2>/dev/null
        
        rm -f output/*.png 2>/dev/null || true
        python inference_img.py \
            --img "$WORK_DIR/transitions/frame_${curr}_last.png" \
                  "$WORK_DIR/transitions/frame_${next}_first.png" \
            --exp=3 2>/dev/null
        
        ffmpeg -y -framerate $FPS -i "output/img%d.png" \
            -c:v libx264 -pix_fmt yuv420p \
            "$WORK_DIR/transitions/transition_${curr}_${next}.mp4" 2>/dev/null
        
        log_info "  ✅ transition_${curr}_${next}.mp4"
    done
    
    log_info "✅ Transitions générées"
else
    log_info "ℹ️  Une seule vidéo, pas de transition nécessaire"
    cp "$WORK_DIR/videos/video_000.mp4" "$OUTPUT_FILE"
fi

# =============================================================================
# ÉTAPE 5: ASSEMBLAGE
# =============================================================================
if [ "$NUM_VIDEOS" -gt 1 ]; then
    log_step "Assemblage..."
    
    cd "$WORK_DIR/final"
    concat_list="concat_list.txt"
    > "$concat_list"
    
    for i in $(seq 0 $((NUM_VIDEOS-1))); do
        curr=$(printf "%03d" $i)
        echo "file '../videos/video_${curr}.mp4'" >> "$concat_list"
        
        if [ $i -lt $((NUM_VIDEOS-1)) ]; then
            next=$(printf "%03d" $((i+1)))
            if [ -f "$WORK_DIR/transitions/transition_${curr}_${next}.mp4" ]; then
                echo "file '../transitions/transition_${curr}_${next}.mp4'" >> "$concat_list"
            fi
        fi
    done
    
    ffmpeg -y -f concat -safe 0 -i concat_list.txt \
        -c:v libx264 -c:a aac -b:a 192k \
        "$OUTPUT_FILE" 2>/dev/null
fi

OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE")
log_info "✅ Vidéo assemblée: $OUTPUT_FILE ($(numfmt --to=iec $OUTPUT_SIZE))"

# =============================================================================
# ÉTAPE 6: UPSCALE x4 (Real-ESRGAN)
# =============================================================================
log_step "Upscale x4 (Real-ESRGAN)..."

cd "$ESRGAN_DIR"

# Extraire les frames
log_info "Extraction des frames..."
ffmpeg -i "$OUTPUT_FILE" -qscale:v 1 -qmin 1 -qmax 1 -vsync 0 "$WORK_DIR/frames/frame%08d.png" 2>/dev/null

FRAME_COUNT=$(ls -1 "$WORK_DIR/frames"/*.png 2>/dev/null | wc -l)
log_info "  $FRAME_COUNT frames extraites"

# Upscale chaque frame
log_info "Upscale des frames (x4)..."
python inference_realesrgan.py \
    -i "$WORK_DIR/frames" \
    -o "$WORK_DIR/frames_up" \
    -n realesr-animevideov3 \
    -s 4 \
    --suffix "" \
    2>/dev/null

# Récupérer le FPS original
ORIGINAL_FPS=$(ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate "$OUTPUT_FILE" | bc -l 2>/dev/null || echo "25")
log_info "  FPS original: $ORIGINAL_FPS"

# Recréer la vidéo upscalée
log_info "Reconstruction vidéo..."
ffmpeg -y -framerate $ORIGINAL_FPS -i "$WORK_DIR/frames_up/frame%08d.png" \
    -i "$OUTPUT_FILE" -map 0:v -map 1:a? \
    -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
    -c:a copy \
    "$UPSCALED_FILE" 2>/dev/null

if [ -f "$UPSCALED_FILE" ]; then
    UPSCALED_SIZE=$(stat -c%s "$UPSCALED_FILE")
    log_info "✅ Vidéo upscalée: $UPSCALED_FILE ($(numfmt --to=iec $UPSCALED_SIZE))"
    FINAL_OUTPUT="$UPSCALED_FILE"
else
    log_error "❌ Upscale échoué, utilisation de la vidéo non-upscalée"
    FINAL_OUTPUT="$OUTPUT_FILE"
fi

# =============================================================================
# ÉTAPE 7: ENVOYER AU WEBHOOK
# =============================================================================
if [ -n "$WEBHOOK_URL" ]; then
    log_step "Envoi vidéo au webhook..."
    
    FINAL_SIZE=$(stat -c%s "$FINAL_OUTPUT")
    
    curl -s -X POST "$WEBHOOK_URL" \
        -F "status=success" \
        -F "project=$PROJECT_NAME" \
        -F "filename=$(basename $FINAL_OUTPUT)" \
        -F "size=$FINAL_SIZE" \
        -F "video=@$FINAL_OUTPUT;type=video/mp4"
    
    log_info "✅ Webhook envoyé"
fi

# =============================================================================
# ÉTAPE 8: CLEANUP
# =============================================================================
log_step "Nettoyage..."
rm -rf "$WORK_DIR"
log_info "✅ Nettoyage OK"

log_info "🎉 Fusion + Upscale terminés!"
