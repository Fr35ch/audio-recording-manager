# User Stories: Recording

**Epic:** Audio Recording
**Date:** 2026-04-14
**Status:** Draft

---

## US-R1: Start a new recording

**As a** researcher,
**I want to** start an audio recording with one click,
**so that** I can begin capturing an interview quickly without technical setup.

### Acceptance Criteria
- [ ] "Start Recording" button is prominent and clearly visible
- [ ] Microphone is verified before recording begins (auto-check with fallback timeout)
- [ ] Recording uses high-quality settings (44.1 kHz, stereo, AAC)
- [ ] Visual feedback confirms recording has started (pulsing red icon, "RECORDING" label)
- [ ] Duration counter begins immediately (MM:SS.D format)

---

## US-R2: See live audio feedback while recording

**As a** researcher,
**I want to** see that the microphone is picking up sound,
**so that** I can verify the recording is working before the interview progresses.

### Acceptance Criteria
- [ ] Scrolling waveform visualization shows audio levels in real-time
- [ ] 32-band frequency visualization updates at 20 Hz
- [ ] Microphone icon glows/pulses in sync with audio levels
- [ ] Voice activity detection (VAD) runs in parallel using FFT analysis

---

## US-R3: Get warned about prolonged silence

**As a** researcher,
**I want to** be alerted if the recording has been silent for too long,
**so that** I can check if there's a microphone problem.

### Acceptance Criteria
- [ ] Silence warning appears after 2 minutes of no speech detected (VAD + audio level)
- [ ] Warning dialog offers: Continue, Pause, or Stop
- [ ] Silence tracking resets after user interaction or speech resumes

---

## US-R4: Pause and resume recording

**As a** researcher,
**I want to** pause the recording during breaks,
**so that** I don't capture unnecessary silence or off-topic conversation.

### Acceptance Criteria
- [ ] Pause button available during active recording
- [ ] Visual indicator changes (duration counter turns orange, "PAUSED" label)
- [ ] Resume continues from the same point without creating a new file
- [ ] Silence tracking resets on resume

---

## US-R5: Name and save a recording

**As a** researcher,
**I want to** give my recording a meaningful name when I stop,
**so that** I can find it later among other recordings.

### Acceptance Criteria
- [ ] Naming dialog appears immediately when recording is stopped
- [ ] Text field is auto-focused for immediate typing
- [ ] Live preview shows final filename: `CustomName_YYYYMMDD_HHMMSS.m4a`
- [ ] Default name is `lydfil_YYYYMMDD_HHMMSS` if no custom name entered
- [ ] Invalid characters (/ and :) are automatically replaced
- [ ] File is saved to `~/Desktop/lydfiler/`
- [ ] Success confirmation shown with green checkmark and filename (auto-dismisses after 3s)

---

## US-R6: Discard a recording

**As a** researcher,
**I want to** delete a recording I don't want to keep,
**so that** I don't clutter my workspace with failed takes.

### Acceptance Criteria
- [ ] Delete button available during active recording (discards immediately)
- [ ] "Discard" option available in the naming dialog after stopping
- [ ] Temporary file is removed from disk
- [ ] App resets to ready state and restarts monitoring

---

## US-R7: Select audio input device

**As a** researcher,
**I want to** choose which microphone to record from,
**so that** I can use an external microphone for better quality.

### Acceptance Criteria
- [ ] Gear icon opens audio source selector (only when not recording)
- [ ] Lists all available audio input devices
- [ ] Selected device is used for the next recording

---

---

## US-R8: Spill av et opptak fra opptaksvisningen

**Added:** 2026-04-17
**Implementation guide:** [RECORDING_DETAIL_VIEW.md](RECORDING_DETAIL_VIEW.md)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å spille av et opptak direkte fra opptaksvisningen,
**slik at** jeg kan lytte gjennom intervjuet og verifisere innholdet uten å forlate appen.

### Acceptance Criteria
- [ ] Spill av / pause-knapp (stor, sentral) spiller av den valgte lydfilen
- [ ] Restart-knapp (backward.end.fill) hopper til begynnelsen av filen
- [ ] Scrubber viser avspillingsposisjon og oppdateres i sanntid
- [ ] Klikk på scrubber søker til ny posisjon i filen
- [ ] Tidsetiketter viser nåværende posisjon og total varighet (MM:SS-format)
- [ ] Mellomrom-taste (space) fungerer som play/pause-snarvei
- [ ] Avspillingstilstand vises korrekt dersom en annen fil spilles i bakgrunnen

---

## US-R9: Transkriber et opptak fra opptaksvisningen

**Added:** 2026-04-17
**Implementation guide:** [RECORDING_DETAIL_VIEW.md](RECORDING_DETAIL_VIEW.md)
**Depends on:** US-T1 (transcription engine), US-T2 (progress UI)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å starte transkribering av et opptak direkte fra opptaksvisningen,
**slik at** jeg kan gå rett fra å lytte til å lese transkripsjonen uten å bytte fane.

### Acceptance Criteria
- [ ] «Transkriber lydfil automatisk»-knapp vises når ingen transkripsjon finnes
- [ ] Valgt modell og antall talere vises som kortfattet oppsummering under knappen (skrivebeskyttet — innstillinger endres i innstillingspanelet)
- [ ] Knappen er deaktivert med forklarende advarsel dersom `no-transcribe` ikke er installert
- [ ] Transkriberingsfremgang vises med spinner, fasevisning og framdriftslinje (se US-T2)
- [ ] «Avbryt»-knapp avbryter prosessen og tilbakestiller tilstand
- [ ] Feil vises inline med «Prøv igjen»-knapp
- [ ] Fullført transkripsjon viser metadata: antall segmenter, antall talere, varighet

---

## US-R10: Åpne transkripsjonseditoren fra opptaksvisningen

**Added:** 2026-04-17
**Implementation guide:** [RECORDING_DETAIL_VIEW.md](RECORDING_DETAIL_VIEW.md)
**Depends on:** US-R9 (transkripsjon må finnes), US-T11 (TranscriptEditorView)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** at «Åpne i transkripsjonseditoren»-knappen tar meg til den samme transkripsjonseditoren som jeg når fra Transkripsjoner-fanen,
**slik at** jeg kan redigere, lytte og anonymisere uten å oppleve to forskjellige grensesnitt for samme data.

### Acceptance Criteria
- [ ] Etter fullført transkripsjon vises en «Åpne i transkripsjonseditoren»-knapp (primærknapp)
- [ ] Trykk på knappen lukker opptaksvisningen og navigerer til Transkripsjoner-fanen med riktig transkripsjon valgt
- [ ] `TranscriptEditorView` som åpnes er **identisk** med den som åpnes fra Transkripsjoner-fanen — ingen separate modaler, ingen read-only variant
- [ ] Den gamle «Vis segmenter»-modalen (`transcriptionResultSheet`) er fjernet og finnes ikke lenger i koden
- [ ] Sekundærknappen «Kjør på nytt» forblir tilgjengelig for å re-kjøre transkriberingen

### Out of scope
- Å åpne transkripsjonseditoren inline i opptaksvisningen (editoren er en fullskjermkomponent i Transkripsjoner-fanen)

---

## US-R11: Taleutskilling fra opptaksvisningen

**Added:** 2026-04-17
**Implementation guide:** [RECORDING_DETAIL_VIEW.md](RECORDING_DETAIL_VIEW.md)
**Depends on:** US-T6 (diarization engine — ikke ferdig)
**Status:** Planlagt — ikke tilgjengelig ennå

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å se at taleutskilling (diarization) er en planlagt funksjon i opptaksvisningen,
**slik at** jeg vet at ARM vil identifisere hvem som snakker, og ikke leter etter et annet verktøy for dette.

### Acceptance Criteria
- [ ] «Taleutskilling»-seksjon vises alltid i opptaksvisningen (ikke bare når transkripsjon finnes)
- [ ] Seksjonen viser beskrivelsen: «Identifiser hvem som snakker i opptaket»
- [ ] «Kjør taleutskilling»-knapp vises, men er **deaktivert**
- [ ] Tooltip på deaktivert knapp: «Taleutskilling kommer i en fremtidig versjon av ARM»
- [ ] Ingen spinner, ingen feilmelding, ingen framdriftsvisning — kun deaktivert knapp
- [ ] Ingen HuggingFace-token-logikk implementeres i dette steget

### Out of scope
- Faktisk kjøring av taleutskilling (implementeres når US-T6 er ferdig)
- HuggingFace-token-konfigurasjon i denne seksjonen

---

## US-R12: Se filinformasjon i opptaksvisningen

**Added:** 2026-04-17
**Implementation guide:** [RECORDING_DETAIL_VIEW.md](RECORDING_DETAIL_VIEW.md)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å se metadata om opptaksfilen i opptaksvisningen,
**slik at** jeg raskt kan bekrefte at jeg ser på riktig intervju.

### Acceptance Criteria
- [ ] «Filinformasjon»-seksjon viser: filnavn, dato, varighet, filstørrelse
- [ ] Verdiene kan markeres og kopieres (`.textSelection(.enabled)`)
- [ ] Seksjonen er alltid synlig, uavhengig av transkripsjonstilstand

---

## Priority Order

| Priority | Story | Status |
|----------|-------|--------|
| 1 | US-R1 | Not started |
| 2 | US-R2 | Not started |
| 3 | US-R5 | Not started |
| 4 | US-R4 | Not started |
| 5 | US-R6 | Not started |
| 6 | US-R3 | Not started |
| 7 | US-R7 | Not started |
| 8 | US-R8 | Not started |
| 9 | US-R9 | Not started |
| 10 | US-R10 | Not started |
| 11 | US-R12 | Not started |
| 12 | US-R11 | Not started (blocked on US-T6) |
