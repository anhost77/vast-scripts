#!/bin/bash
# =============================================================================
# CoquiTTS XTTS v2 - Installation et generation audio
# =============================================================================
# Usage: 
#   bash coqui_tts.sh --webhook "https://..." --text-content "Texte a generer"
#   bash coqui_tts.sh --webhook "https://..." --text "fichier.txt" --speed 0.9
# =============================================================================

set -e
# Accepter la licence Coqui automatiquement
export COQUI_TOS_AGREED=1

# =============================================================================
# CONFIGURATION PAR DEFAUT
# =============================================================================
WEBHOOK_URL=""
VOICE_GDRIVE_ID="1u0uwukYeufwmac9qyCHTxgtH0ejmX35T"
TEXT_FILE=""
TEXT_CONTENT=""
OUTPUT_FORMAT="mp3"
WORK_DIR="/workspace/coqui-tts"
LANGUAGE="fr"
SKIP_INSTALL=false

# Parametres de qualite audio
SPEED="0.9"
TEMPERATURE="0.65"
TOP_K="50"
TOP_P="0.85"
REPETITION_PENALTY="5.0"
LENGTH_PENALTY="1.0"
SPLIT_SENTENCES="True"

# =============================================================================
# PARSING DES ARGUMENTS
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --voice)
            VOICE_GDRIVE_ID="$2"
            shift 2
            ;;
        --text)
            TEXT_FILE="$2"
            shift 2
            ;;
        --text-content)
            TEXT_CONTENT="$2"
            shift 2
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --workdir)
            WORK_DIR="$2"
            shift 2
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --speed)
            SPEED="$2"
            shift 2
            ;;
        --temperature)
            TEMPERATURE="$2"
            shift 2
            ;;
        --top-k)
            TOP_K="$2"
            shift 2
            ;;
        --top-p)
            TOP_P="$2"
            shift 2
            ;;
        --repetition-penalty)
            REPETITION_PENALTY="$2"
            shift 2
            ;;
        --length-penalty)
            LENGTH_PENALTY="$2"
            shift 2
            ;;
        --no-split)
            SPLIT_SENTENCES="False"
            shift
            ;;
        --help)
            echo "Usage: bash coqui_tts.sh [OPTIONS]"
            echo ""
            echo "Options principales:"
            echo "  --webhook URL          URL du webhook pour envoyer le resultat"
            echo "  --voice ID             Google Drive ID du fichier audio de reference"
            echo "  --text FILE            Fichier texte contenant le script a generer"
            echo "  --text-content TEXT    Texte direct a generer (alternative a --text)"
            echo "  --format FORMAT        Format de sortie: mp3 ou wav (defaut: mp3)"
            echo "  --language LANG        Langue: fr, en, es, de, etc. (defaut: fr)"
            echo "  --workdir DIR          Repertoire de travail (defaut: /workspace/coqui-tts)"
            echo "  --skip-install         Passer l'installation si deja fait"
            echo ""
            echo "Parametres de qualite audio:"
            echo "  --speed VALUE          Vitesse: 0.8=lent, 1.0=normal, 1.2=rapide (defaut: 0.9)"
            echo "  --temperature VALUE    Expressivite: 0.5=stable, 0.75=normal, 0.9=expressif (defaut: 0.65)"
            echo "  --top-k VALUE          Diversite tokens: 10-100 (defaut: 50)"
            echo "  --top-p VALUE          Nucleus sampling: 0.5-1.0 (defaut: 0.85)"
            echo "  --repetition-penalty   Penalite repetition: 1.0-10.0 (defaut: 5.0)"
            echo "  --length-penalty       Penalite longueur: 0.5-2.0 (defaut: 1.0)"
            echo "  --no-split             Desactiver le decoupage en phrases"
            echo ""
            echo "  --help                 Afficher cette aide"
            exit 0
            ;;
        *)
            echo "Option inconnue: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }

# =============================================================================
# VERIFICATIONS
# =============================================================================
if [ -z "$WEBHOOK_URL" ]; then
    error "L'URL du webhook est obligatoire (--webhook)"
fi

if [ -z "$TEXT_FILE" ] && [ -z "$TEXT_CONTENT" ]; then
    error "Un texte est obligatoire (--text ou --text-content)"
fi

# =============================================================================
# ETAPE 1 : INSTALLATION DES DEPENDANCES
# =============================================================================
install_dependencies() {
    log "Verification des dependances..."
    
    # Accepter la licence Coqui automatiquement
    export COQUI_TOS_AGREED=1
    
    # Verifier si TTS est deja installe et fonctionnel
    if python3 -c "import os; os.environ['COQUI_TOS_AGREED']='1'; from TTS.api import TTS; print('OK')" 2>/dev/null | grep -q "OK"; then
        log "CoquiTTS deja installe"
        return 0
    fi
    
    log "Installation des dependances systeme..."
    apt-get update -qq
    apt-get install -y -qq ffmpeg curl > /dev/null 2>&1
    
    log "Installation de gdown..."
    pip install -q gdown
    
    log "Installation de CoquiTTS (peut prendre quelques minutes)..."
    
    # Installer avec les bonnes versions
    pip install torch==2.5.1 torchaudio==2.5.1 -q 2>/dev/null || true
    pip install transformers==4.40.0 tokenizers==0.19.1 -q 2>/dev/null || true
    pip install TTS -q 2>/dev/null || pip install TTS --ignore-installed blinker -q
    
    log "Installation terminee"
}

# =============================================================================
# ETAPE 2 : TELECHARGER LE MODELE ET ACCEPTER LA LICENCE
# =============================================================================
setup_model() {
    log "Configuration du modele XTTS v2..."
    
    mkdir -p "$WORK_DIR/audio" "$WORK_DIR/output"
    
    # Verifier si le modele est deja telecharge
    MODEL_DIR="$HOME/.local/share/tts/tts_models--multilingual--multi-dataset--xtts_v2"
    
    if [ -d "$MODEL_DIR" ] && [ -f "$MODEL_DIR/model.pth" ]; then
        log "Modele XTTS v2 deja telecharge"
        return 0
    fi
    
    log "Telechargement du modele XTTS v2 (acceptation automatique de la licence)..."
    
    # Telecharger et accepter la licence automatiquement
    python3 << 'PYTHON_SETUP'
import os
os.environ['COQUI_TOS_AGREED'] = '1'

from TTS.api import TTS
import torch

device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Device: {device}")

# Ceci telecharge le modele et accepte la licence
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
print("Modele XTTS v2 pret")
PYTHON_SETUP
    
    log "Modele configure"
}

# =============================================================================
# ETAPE 3 : TELECHARGER LA VOIX DE REFERENCE
# =============================================================================
download_voice() {
    log "Telechargement de la voix de reference..."
    
    VOICE_FILE="$WORK_DIR/audio/voice_reference.wav"
    
    if [ -f "$VOICE_FILE" ]; then
        log "Voix de reference deja presente"
        return 0
    fi
    
    # Telecharger depuis Google Drive
    gdown "https://drive.google.com/uc?id=$VOICE_GDRIVE_ID" -O "$WORK_DIR/audio/voice_raw.mp3" --quiet || \
    error "Impossible de telecharger la voix depuis Google Drive (ID: $VOICE_GDRIVE_ID)"
    
    # Convertir en WAV 22050Hz mono (optimal pour XTTS)
    ffmpeg -i "$WORK_DIR/audio/voice_raw.mp3" -ar 22050 -ac 1 "$WORK_DIR/audio/voice_full.wav" -y -loglevel error
    
    # Extraire 30 secondes (suffisant pour clonage)
    ffmpeg -i "$WORK_DIR/audio/voice_full.wav" -t 30 "$VOICE_FILE" -y -loglevel error
    
    log "Voix de reference prete: $VOICE_FILE"
}

# =============================================================================
# ETAPE 4 : GENERER L'AUDIO
# =============================================================================
generate_audio() {
    log "Generation de l'audio..."
    log "Parametres: speed=$SPEED, temperature=$TEMPERATURE, top_k=$TOP_K, top_p=$TOP_P"
    
    # Recuperer le texte
    if [ -n "$TEXT_FILE" ]; then
        if [ ! -f "$TEXT_FILE" ]; then
            error "Fichier texte introuvable: $TEXT_FILE"
        fi
        SCRIPT_TEXT=$(cat "$TEXT_FILE")
    else
        SCRIPT_TEXT="$TEXT_CONTENT"
    fi
    
    OUTPUT_WAV="$WORK_DIR/output/generated.wav"
    OUTPUT_FINAL="$WORK_DIR/output/generated.$OUTPUT_FORMAT"
    VOICE_FILE="$WORK_DIR/audio/voice_reference.wav"
    
    # Generer l'audio avec Python
    python3 << PYTHON_GENERATE
import os
os.environ['COQUI_TOS_AGREED'] = '1'

from TTS.api import TTS
import torch

device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Device: {device}")

tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)

text = '''$SCRIPT_TEXT'''

print(f"Texte a generer ({len(text)} caracteres)...")

tts.tts_to_file(
    text=text,
    file_path="$OUTPUT_WAV",
    speaker_wav="$VOICE_FILE",
    language="$LANGUAGE",
    speed=$SPEED,
    temperature=$TEMPERATURE,
    top_k=$TOP_K,
    top_p=$TOP_P,
    repetition_penalty=$REPETITION_PENALTY,
    length_penalty=$LENGTH_PENALTY,
    split_sentences=$SPLIT_SENTENCES
)

print("Audio genere: $OUTPUT_WAV")
PYTHON_GENERATE
    
    # Convertir en MP3 si demande
    if [ "$OUTPUT_FORMAT" = "mp3" ]; then
        log "Conversion en MP3..."
        ffmpeg -i "$OUTPUT_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT_FINAL" -y -loglevel error
        rm -f "$OUTPUT_WAV"
    else
        mv "$OUTPUT_WAV" "$OUTPUT_FINAL"
    fi
    
    log "Audio final: $OUTPUT_FINAL"
}

# =============================================================================
# ETAPE 5 : ENVOYER LE RESULTAT
# =============================================================================
send_result() {
    log "Envoi du resultat vers $WEBHOOK_URL..."
    
    OUTPUT_FINAL="$WORK_DIR/output/generated.$OUTPUT_FORMAT"
    FILENAME="generated_$(date +%Y%m%d_%H%M%S).$OUTPUT_FORMAT"
    
    # Recuperer le texte pour l'envoyer avec
    if [ -n "$TEXT_FILE" ]; then
        SCRIPT_TEXT=$(cat "$TEXT_FILE")
    else
        SCRIPT_TEXT="$TEXT_CONTENT"
    fi
    
    # Envoyer via curl en multipart
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
        -F "file=@$OUTPUT_FINAL;filename=$FILENAME" \
        -F "filename=$FILENAME" \
        -F "language=$LANGUAGE" \
        -F "speed=$SPEED" \
        -F "temperature=$TEMPERATURE" \
        -F "text=$SCRIPT_TEXT")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        log "Envoi reussi (HTTP $HTTP_CODE)"
        log "Reponse: $BODY"
    else
        log "Envoi termine avec code HTTP $HTTP_CODE"
        log "Reponse: $BODY"
    fi
}

# =============================================================================
# EXECUTION PRINCIPALE
# =============================================================================
main() {
    log "Demarrage CoquiTTS XTTS v2"
    log "Webhook: $WEBHOOK_URL"
    log "Voice ID: $VOICE_GDRIVE_ID"
    log "Format: $OUTPUT_FORMAT"
    log "Langue: $LANGUAGE"
    
    if [ "$SKIP_INSTALL" = false ]; then
        install_dependencies
    fi
    
    setup_model
    download_voice
    generate_audio
    send_result
    
    log "Termine!"
}

# Lancer
main
