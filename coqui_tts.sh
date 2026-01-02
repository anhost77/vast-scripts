#!/bin/bash
# =============================================================================
# CoquiTTS XTTS v2 - Installation et génération audio
# =============================================================================
# Usage: 
#   bash coqui_tts.sh --webhook "https://..." --voice "GDRIVE_ID" --text "fichier.txt"
#   bash coqui_tts.sh --webhook "https://..." --voice "GDRIVE_ID" --text-content "Texte à générer"
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION PAR DÉFAUT
# =============================================================================
WEBHOOK_URL=""
VOICE_GDRIVE_ID="1u0uwukYeufwmac9qyCHTxgtH0ejmX35T"
TEXT_FILE=""
TEXT_CONTENT=""
OUTPUT_FORMAT="mp3"
WORK_DIR="/workspace/coqui-tts"
LANGUAGE="fr"
SKIP_INSTALL=false

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
        --help)
            echo "Usage: bash coqui_tts.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --webhook URL        URL du webhook pour envoyer le résultat"
            echo "  --voice ID           Google Drive ID du fichier audio de référence"
            echo "  --text FILE          Fichier texte contenant le script à générer"
            echo "  --text-content TEXT  Texte direct à générer (alternative à --text)"
            echo "  --format FORMAT      Format de sortie: mp3 ou wav (défaut: mp3)"
            echo "  --language LANG      Langue: fr, en, es, de, etc. (défaut: fr)"
            echo "  --workdir DIR        Répertoire de travail (défaut: /workspace/coqui-tts)"
            echo "  --skip-install       Passer l'installation si déjà fait"
            echo "  --help               Afficher cette aide"
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
# VÉRIFICATIONS
# =============================================================================
if [ -z "$WEBHOOK_URL" ]; then
    error "L'URL du webhook est obligatoire (--webhook)"
fi

if [ -z "$TEXT_FILE" ] && [ -z "$TEXT_CONTENT" ]; then
    error "Un texte est obligatoire (--text ou --text-content)"
fi

# =============================================================================
# ÉTAPE 1 : INSTALLATION DES DÉPENDANCES
# =============================================================================
install_dependencies() {
    log "📦 Vérification des dépendances..."
    
    # Vérifier si TTS est déjà installé et fonctionnel
    if python3 -c "from TTS.api import TTS; print('OK')" 2>/dev/null | grep -q "OK"; then
        log "✅ CoquiTTS déjà installé"
        return 0
    fi
    
    log "📦 Installation des dépendances système..."
    apt-get update -qq
    apt-get install -y -qq ffmpeg curl > /dev/null 2>&1
    
    log "📦 Installation de gdown..."
    pip install -q gdown
    
    log "📦 Installation de CoquiTTS (peut prendre quelques minutes)..."
    
    # Installer avec les bonnes versions pour éviter les conflits
    pip install torch==2.5.1 torchaudio==2.5.1 --break-system-packages -q 2>/dev/null || true
    pip install transformers==4.40.0 tokenizers==0.19.1 --break-system-packages -q 2>/dev/null || true
    pip install TTS --break-system-packages -q 2>/dev/null || \
    pip install TTS --ignore-installed blinker --break-system-packages -q
    
    log "✅ Installation terminée"
}

# =============================================================================
# ÉTAPE 2 : TÉLÉCHARGER LE MODÈLE ET ACCEPTER LA LICENCE
# =============================================================================
setup_model() {
    log "🧠 Configuration du modèle XTTS v2..."
    
    mkdir -p "$WORK_DIR/audio" "$WORK_DIR/output"
    
    # Vérifier si le modèle est déjà téléchargé
    MODEL_DIR="$HOME/.local/share/tts/tts_models--multilingual--multi-dataset--xtts_v2"
    
    if [ -d "$MODEL_DIR" ] && [ -f "$MODEL_DIR/model.pth" ]; then
        log "✅ Modèle XTTS v2 déjà téléchargé"
        return 0
    fi
    
    log "🧠 Téléchargement du modèle XTTS v2 (acceptation automatique de la licence)..."
    
    # Télécharger et accepter la licence automatiquement
    python3 << 'PYTHON_SETUP'
import os
os.environ['COQUI_TOS_AGREED'] = '1'

from TTS.api import TTS
import torch

device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Device: {device}")

# Ceci télécharge le modèle et accepte la licence
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
print("✅ Modèle XTTS v2 prêt")
PYTHON_SETUP
    
    log "✅ Modèle configuré"
}

# =============================================================================
# ÉTAPE 3 : TÉLÉCHARGER LA VOIX DE RÉFÉRENCE
# =============================================================================
download_voice() {
    log "🎤 Téléchargement de la voix de référence..."
    
    VOICE_FILE="$WORK_DIR/audio/voice_reference.wav"
    
    if [ -f "$VOICE_FILE" ]; then
        log "✅ Voix de référence déjà présente"
        return 0
    fi
    
    # Télécharger depuis Google Drive
    gdown "https://drive.google.com/uc?id=$VOICE_GDRIVE_ID" -O "$WORK_DIR/audio/voice_raw.mp3" --quiet || \
    error "Impossible de télécharger la voix depuis Google Drive (ID: $VOICE_GDRIVE_ID)"
    
    # Convertir en WAV 22050Hz mono (optimal pour XTTS)
    ffmpeg -i "$WORK_DIR/audio/voice_raw.mp3" -ar 22050 -ac 1 "$WORK_DIR/audio/voice_full.wav" -y -loglevel error
    
    # Extraire 30 secondes (suffisant pour clonage)
    ffmpeg -i "$WORK_DIR/audio/voice_full.wav" -t 30 "$VOICE_FILE" -y -loglevel error
    
    log "✅ Voix de référence prête: $VOICE_FILE"
}

# =============================================================================
# ÉTAPE 4 : GÉNÉRER L'AUDIO
# =============================================================================
generate_audio() {
    log "🎙️ Génération de l'audio..."
    
    # Récupérer le texte
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
    
    # Générer l'audio avec Python
    python3 << PYTHON_GENERATE
import os
os.environ['COQUI_TOS_AGREED'] = '1'

from TTS.api import TTS
import torch

device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Device: {device}")

tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)

text = '''$SCRIPT_TEXT'''

print(f"Texte à générer ({len(text)} caractères)...")

tts.tts_to_file(
    text=text,
    file_path="$OUTPUT_WAV",
    speaker_wav="$VOICE_FILE",
    language="$LANGUAGE"
)

print("✅ Audio généré: $OUTPUT_WAV")
PYTHON_GENERATE
    
    # Convertir en MP3 si demandé
    if [ "$OUTPUT_FORMAT" = "mp3" ]; then
        log "🔄 Conversion en MP3..."
        ffmpeg -i "$OUTPUT_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT_FINAL" -y -loglevel error
        rm -f "$OUTPUT_WAV"
    else
        mv "$OUTPUT_WAV" "$OUTPUT_FINAL"
    fi
    
    log "✅ Audio final: $OUTPUT_FINAL"
}

# =============================================================================
# ÉTAPE 5 : ENVOYER LE RÉSULTAT
# =============================================================================
send_result() {
    log "📤 Envoi du résultat vers $WEBHOOK_URL..."
    
    OUTPUT_FINAL="$WORK_DIR/output/generated.$OUTPUT_FORMAT"
    FILENAME="generated_$(date +%Y%m%d_%H%M%S).$OUTPUT_FORMAT"
    
    # Récupérer le texte pour l'envoyer avec
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
        -F "text=$SCRIPT_TEXT")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        log "✅ Envoi réussi (HTTP $HTTP_CODE)"
        log "Réponse: $BODY"
    else
        log "⚠️ Envoi terminé avec code HTTP $HTTP_CODE"
        log "Réponse: $BODY"
    fi
}

# =============================================================================
# EXÉCUTION PRINCIPALE
# =============================================================================
main() {
    log "🚀 Démarrage CoquiTTS XTTS v2"
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
    
    log "🎉 Terminé !"
}

# Lancer
main
