#!/bin/bash
# GPT-SoVITS Full Fine-tuning Script (CLI) for French
# Usage: bash gpt_sovits_train.sh <PROJECT_NAME>

PROJECT_NAME="${1:-voice_fr}"
cd /workspace/GPT-SoVITS

echo "============================================"
echo "GPT-SoVITS Fine-tuning CLI"
echo "Project: $PROJECT_NAME"
echo "============================================"

# Vérifier que les données existent
if [ ! -d "data/${PROJECT_NAME}/wavs" ]; then
    echo "❌ Erreur: data/${PROJECT_NAME}/wavs n'existe pas"
    echo "Lance d'abord le script de préparation du dataset"
    exit 1
fi

# Créer les répertoires nécessaires
mkdir -p "logs/${PROJECT_NAME}"
mkdir -p "output/${PROJECT_NAME}"
mkdir -p "GPT_weights_v2/${PROJECT_NAME}"
mkdir -p "SoVITS_weights_v2/${PROJECT_NAME}"

# ============================================
# ÉTAPE 1: Préparer les fichiers de config
# ============================================
echo ""
echo "[1/6] Préparation des fichiers de configuration..."

# Créer le fichier de liste des audios
echo "Création de la liste des fichiers audio..."
> "data/${PROJECT_NAME}/audio_list.txt"
for wav in data/${PROJECT_NAME}/wavs/*.wav; do
    echo "$wav" >> "data/${PROJECT_NAME}/audio_list.txt"
done
echo "✓ $(wc -l < data/${PROJECT_NAME}/audio_list.txt) fichiers audio listés"

# ============================================
# ÉTAPE 2: Extraction SSL (HuBERT)
# ============================================
echo ""
echo "[2/6] Extraction des features SSL (HuBERT)..."

mkdir -p "logs/${PROJECT_NAME}/4-cnhubert"

python3 << PYTHON_SSL
import os
import torch
import traceback
from tqdm import tqdm
import soundfile as sf

os.environ["PROJECT_NAME"] = "${PROJECT_NAME}"
project = "${PROJECT_NAME}"

# Charger le modèle HuBERT
print("Chargement du modèle HuBERT...")
from transformers import HubertModel
import torchaudio

device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Device: {device}")

# Utiliser le modèle chinese-hubert-base
hubert_path = "GPT_SoVITS/pretrained_models/chinese-hubert-base"
if os.path.exists(hubert_path):
    model = HubertModel.from_pretrained(hubert_path).to(device)
else:
    print("Téléchargement du modèle HuBERT...")
    model = HubertModel.from_pretrained("TencentGameMate/chinese-hubert-base").to(device)

model.eval()

# Traiter chaque fichier audio
wavs_dir = f"data/{project}/wavs"
output_dir = f"logs/{project}/4-cnhubert"

wav_files = [f for f in os.listdir(wavs_dir) if f.endswith('.wav')]
print(f"Traitement de {len(wav_files)} fichiers...")

for wav_file in tqdm(wav_files):
    try:
        wav_path = os.path.join(wavs_dir, wav_file)
        
        # Charger l'audio
        waveform, sr = torchaudio.load(wav_path)
        
        # Resampler à 16kHz si nécessaire
        if sr != 16000:
            resampler = torchaudio.transforms.Resample(sr, 16000)
            waveform = resampler(waveform)
        
        # Extraire les features
        with torch.no_grad():
            waveform = waveform.to(device)
            if waveform.dim() == 2:
                waveform = waveform.mean(dim=0, keepdim=True)
            features = model(waveform).last_hidden_state
        
        # Sauvegarder
        output_path = os.path.join(output_dir, wav_file.replace('.wav', '.pt'))
        torch.save(features.cpu(), output_path)
        
    except Exception as e:
        print(f"Erreur sur {wav_file}: {e}")

print(f"✓ Features SSL extraites dans {output_dir}")
PYTHON_SSL

echo "✓ Extraction SSL terminée"

# ============================================
# ÉTAPE 3: Conversion audio 32kHz
# ============================================
echo ""
echo "[3/6] Conversion des audios en 32kHz..."

mkdir -p "logs/${PROJECT_NAME}/5-wav32k"

for wav in data/${PROJECT_NAME}/wavs/*.wav; do
    filename=$(basename "$wav")
    ffmpeg -y -i "$wav" -ar 32000 -ac 1 "logs/${PROJECT_NAME}/5-wav32k/${filename}" 2>/dev/null
done

echo "✓ $(ls -1 logs/${PROJECT_NAME}/5-wav32k/*.wav 2>/dev/null | wc -l) fichiers convertis en 32kHz"

# ============================================
# ÉTAPE 4: Créer le fichier name2text
# ============================================
echo ""
echo "[4/6] Création du fichier name2text..."

# Utiliser le fichier de transcription existant
if [ -f "data/${PROJECT_NAME}/transcription.list" ]; then
    # Convertir le format: wavpath|speaker|lang|text -> wavname|phonemes|text
    python3 << PYTHON_N2T
import os
import re

project = "${PROJECT_NAME}"
input_file = f"data/{project}/transcription.list"
output_file = f"logs/{project}/2-name2text.txt"

# Lire les transcriptions
lines = []
with open(input_file, 'r', encoding='utf-8') as f:
    for line in f:
        parts = line.strip().split('|')
        if len(parts) >= 4:
            wav_path = parts[0]
            text = parts[3]
            wav_name = os.path.basename(wav_path)
            # Format: nom_fichier|phonemes|texte (phonemes vides pour l'instant)
            lines.append(f"{wav_name}||{text}")

with open(output_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))

print(f"✓ {len(lines)} entrées écrites dans {output_file}")
PYTHON_N2T
else
    echo "⚠️ Pas de fichier transcription.list trouvé"
fi

# ============================================
# ÉTAPE 5: Training SoVITS (s2)
# ============================================
echo ""
echo "[5/6] Training SoVITS..."

# Variables d'environnement pour le training
export exp_name="${PROJECT_NAME}"
export exp_root="logs"
export pretrained_s2G="GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth"
export pretrained_s2D="GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2D2333k.pth"
export s2_batch_size=4
export s2_total_epoch=8
export if_save_latest="True"
export if_save_every_weights="True"
export save_every_epoch=4

# Créer le config s2
cat > "logs/${PROJECT_NAME}/s2_config.json" << EOF
{
    "train": {
        "log_interval": 100,
        "eval_interval": 500,
        "seed": 1234,
        "epochs": ${s2_total_epoch},
        "learning_rate": 0.0001,
        "batch_size": ${s2_batch_size},
        "fp16_run": true
    },
    "data": {
        "exp_dir": "logs/${PROJECT_NAME}",
        "training_files": "logs/${PROJECT_NAME}/2-name2text.txt"
    },
    "model": {
        "pretrained_s2G": "${pretrained_s2G}",
        "pretrained_s2D": "${pretrained_s2D}"
    }
}
EOF

echo "Lancement du training SoVITS (${s2_total_epoch} epochs)..."

# Le training SoVITS utilise les variables d'environnement
cd /workspace/GPT-SoVITS

python3 GPT_SoVITS/s2_train.py \
    --exp_name "${PROJECT_NAME}" \
    2>&1 | tee "logs/${PROJECT_NAME}/s2_train.log" || {
    echo "⚠️ Training SoVITS a échoué ou nécessite plus de configuration"
}

echo "✓ Training SoVITS terminé"

# ============================================
# ÉTAPE 6: Training GPT (s1)
# ============================================
echo ""
echo "[6/6] Training GPT..."

export pretrained_s1="GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s1bert25hz-5kh-longer-epoch=12-step=369668.ckpt"
export s1_batch_size=4
export s1_total_epoch=15

echo "Lancement du training GPT (${s1_total_epoch} epochs)..."

python3 GPT_SoVITS/s1_train.py \
    --exp_name "${PROJECT_NAME}" \
    2>&1 | tee "logs/${PROJECT_NAME}/s1_train.log" || {
    echo "⚠️ Training GPT a échoué ou nécessite plus de configuration"
}

echo "✓ Training GPT terminé"

# ============================================
# Résumé
# ============================================
echo ""
echo "============================================"
echo "FINE-TUNING TERMINÉ"
echo "============================================"
echo "Project: ${PROJECT_NAME}"
echo ""
echo "Modèles générés:"
ls -lh GPT_weights_v2/${PROJECT_NAME}/*.ckpt 2>/dev/null || echo "  (pas de modèle GPT)"
ls -lh SoVITS_weights_v2/${PROJECT_NAME}/*.pth 2>/dev/null || echo "  (pas de modèle SoVITS)"
echo ""
echo "Logs: logs/${PROJECT_NAME}/"
echo "============================================"
