# Audio Recording Manager

macOS-app for opptak, transkripsjon, talerutskilling og analyse av brukerintervjuer.
Utviklet for NAV Arbeids- og velferdsdirektoratet.

**Versjon**: 1.4.0 · **Krever**: macOS 14 Sonoma · Apple Silicon · 16 GB RAM · 30 GB ledig disk

---

## Funksjonalitet

| Steg | Funksjon | Avhengighet |
|------|----------|-------------|
| 🎙️ Opptak | Innspilling direkte i appen | Mikrofontilgang |
| 📝 Transkripsjon | Norsk tale-til-tekst via NB-Whisper | Python 3.10+ · no-transcribe |
| 👥 Talerutskilling | Identifiser hvem som snakker | HuggingFace-token · pyannote |
| 🧠 Analyse | Strukturert AI-oppsummering | Ollama med LLM-modell |
| 🔒 Anonymisering | Fjern navn og personnummer | no-anonymizer |
| 📼 DS2-støtte | Olympus DS2-filer (stub) | VMware + Olympus DSS Player |

---

## Oppsett — steg for steg

### 1. Xcode

Last ned **Xcode** fra Mac App Store (gratis).
Åpne Xcode én gang og godta lisensavtalen, deretter:

```bash
xcode-select --install
```

Klon og åpne prosjektet:

```bash
git clone <repo-url> ~/Github/ARM-xcode
open ~/Github/ARM-xcode/AudioRecordingManager.xcodeproj
```

Trykk **⌘B** for å bygge. Trykk **⌘R** for å kjøre.

---

### 2. Python 3.10+

Appen krever Python 3.10 eller nyere for transkripsjon.

```bash
# Sjekk installert versjon
python3 --version

# Installer via Homebrew hvis nødvendig
brew install python@3.12
```

Homebrew installeres med:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

---

### 3. no-transcribe (transkripsjon)

**no-transcribe** er transkripsjonsmotoren. Appen installerer den automatisk i et virtuelt
miljø første gang du trykker **Installer** i Innstillinger → Transkripsjon.

Manuell kloning (navt.py leses fra `~/Github/no-transcribe/`):

```bash
git clone https://github.com/Fr35ch/no-transcribe.git ~/Github/no-transcribe
```

Det virtuelle miljøet med avhengigheter opprettes automatisk av appen. For manuell installasjon:

```bash
python3.12 -m venv ~/Library/Application\ Support/AudioRecordingManager/no-transcribe-venv
source ~/Library/Application\ Support/AudioRecordingManager/no-transcribe-venv/bin/activate
pip install torch torchaudio transformers numpy requests
```

**NB-Whisper-modell** lastes ned automatisk første gang du transkriberer.
Du kan forhåndslaste den via Innstillinger → Transkripsjon → Last ned modell.

| Modell | Størrelse | Nedlastningstid | Anbefaling |
|--------|-----------|-----------------|------------|
| tiny | ~150 MB | 1–2 min | Testing |
| base | ~300 MB | 2–4 min | Korte klipp |
| medium | ~1.4 GB | 10–20 min | Balansert |
| large | ~3 GB | 20–40 min | ✅ Anbefalt |

---

### 4. HuggingFace-token (talerutskilling)

Talerutskilling bruker **pyannote.audio** og krever en HuggingFace-konto med
godkjent modelltilgang.

1. Opprett gratis konto på [huggingface.co](https://huggingface.co)
2. Gå til [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1) og trykk **Accept**
3. Gjør det samme for [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
4. Gå til [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
5. Trykk **New token** → velg **Read**-tilgang → kopier tokenet
6. Åpne appen → trykk ⚙️ (Innstillinger) → lim inn tokenet under **HuggingFace-token**

> Begge modellene (punkt 2 og 3) må godkjennes separat — ellers feiler talerutskilling
> med «Token not authorized».

---

### 5. Ollama (analyse)

**Ollama** kjører språkmodeller lokalt for AI-analyse av transkripsjoner.

**Installer Ollama:**

```bash
brew install ollama
```

Eller last ned installasjonspakken fra [ollama.com](https://ollama.com).

**Last ned en modell** (anbefalt: qwen3:8b, ~5 GB):

```bash
ollama pull qwen3:8b
```

Andre modeller:

```bash
ollama pull llama3.2        # ~2 GB — raskere, litt lavere kvalitet
ollama pull qwen3:14b       # ~9 GB — høyere kvalitet, krever 32 GB RAM
```

Appen starter Ollama automatisk ved behov. Verifiser at det fungerer:

```bash
curl http://localhost:11434   # Skal returnere "Ollama is running"
```

Velg ønsket modell i Innstillinger → **LLM-modell**. Standard er `qwen3:8b`.

---

### 6. DS2-filer (Olympus-opptakere)

DS2 er et proprietært kryptert format brukt av Olympus/OM System-opptakere.
Dekoding krever **Olympus DSS Player Pro**, som kun er tilgjengelig for Windows.

**Løsning: VMware Fusion + Windows**

1. Last ned **VMware Fusion** (gratis for personlig bruk) fra [vmware.com](https://www.vmware.com/products/fusion.html)
2. Installer en Windows 10 eller 11 VM
3. Installer **Olympus DSS Player Pro** i Windows-VM-en
   - Lisens kjøpes fra Olympus/OM System
   - Alternativt: bruk prøveversjon for konvertering
4. Åpne DS2-filen i DSS Player og eksporter til WAV eller MP3
5. Del den konverterte filen til macOS via VMwares delte mapper:
   - VMware Fusion → Settings → Sharing → aktiver delt mappe
   - Filer er tilgjengelige under `/Volumes/VMware Shared Folders/` på Mac

Importer den konverterte WAV/MP3-filen i ARM som vanlig.

> **Merk**: Direkte DS2-dekoding i ARM er under utvikling og avventer tilgang til
> OM System Audio SDK ([audiodeveloper.omsystem.com](https://audiodeveloper.omsystem.com)).

---

### 7. no-anonymizer (valgfritt)

For automatisk anonymisering av navn og personnummer i transkripsjoner:

```bash
pip install "no-anonymizer[ner]"
```

BERT-modellen (~500 MB) lastes automatisk ned fra HuggingFace ved første bruk.

---

## Systemkrav

| Krav | Minimum | Anbefalt |
|------|---------|----------|
| Mac | Apple Silicon (M1+) | M2 Pro / M3 |
| macOS | 14 Sonoma | 15 Sequoia |
| RAM | 16 GB | 32 GB |
| Ledig disk | 30 GB | 50 GB |
| Python | 3.10 | 3.12 |

> Intel Mac støttes ikke. NB-Whisper er optimalisert for Apple MPS (Metal Performance Shaders).

---

## Hurtigstart

1. Start appen — velkomstsplash viser status for alle avhengigheter
2. Trykk ⚙️ → verifiser at no-transcribe er installert (grønt avkrysningsmerke)
3. Importer eller spill inn en lydfil
4. Velg filen → trykk **Transkriber** (large-modell anbefales)
5. Etter transkripsjon → trykk **Identifiser talere**
6. Etter talerutskilling → trykk **Analyser**

---

## Lagring

```
~/Library/Application Support/AudioRecordingManager/
├── no-transcribe-venv/     # Python-miljø (installeres automatisk)
├── transcripts/            # Transkripsjoner (JSON)
├── analysis/               # Analyseresultater (JSON)
└── processing-state.json   # Behandlingsstatus per fil

~/.cache/huggingface/hub/   # NB-Whisper og pyannote-modeller
```

---

## Feilsøking

| Feilmelding | Løsning |
|-------------|---------|
| «no-transcribe ikke installert» | Innstillinger → Installer |
| «NB-Whisper-modell ikke funnet» | Innstillinger → Last ned modell → Large |
| «Ollama er ikke installert» | `brew install ollama` + `ollama pull qwen3:8b` |
| «Ollama kjører ikke» | `ollama serve` i Terminal |
| «Krever HuggingFace-token» | Følg steg 4, godkjenn begge pyannote-modellene |
| «Token not authorized» (pyannote) | Godkjenn modellene på HuggingFace (steg 4.2 og 4.3) |
| Appen starter ikke | Sjekk at Mac er Apple Silicon: `uname -m` → `arm64` |
| Treg transkripsjon | Lukk andre apper for å frigjøre RAM til MPS |

---

## Avhengigheter og lisenser

| Komponent | Lisens |
|-----------|--------|
| NbAiLab/nb-whisper-large | Apache 2.0 |
| pyannote.audio 3.1 | MIT (krever modellgodkjenning) |
| Ollama | MIT |
| qwen3:8b | Qwen License |
| no-anonymizer | Apache 2.0 |
