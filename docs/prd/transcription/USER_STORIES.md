# User Stories: Transcription

**Epic:** Audio Transcription
**Date:** 2026-04-14
**Status:** Draft

---

## US-T1: Transcribe a recording automatically

**As a** researcher,
**I want to** transcribe my audio recording to text with one click,
**so that** I can work with the interview content without listening through the whole file.

### Acceptance Criteria
- [ ] "Transkriber lydfil automatisk" button available in recording detail view
- [ ] Transcription uses no-transcribe (NB-Whisper) via subprocess
- [ ] Default settings applied: model size, speaker count, language, verbatim mode
- [ ] Transcript saved to metadata sidecar (`.metadata.json`) and plain text (`~/Desktop/tekstfiler/<stem>.txt`)
- [ ] JSON result with segments saved to `~/Library/Application Support/AudioRecordingManager/transcripts/`

---

## US-T2: See transcription progress

**As a** researcher,
**I want to** see how far along the transcription is,
**so that** I know it's working and can estimate when it will finish.

### Acceptance Criteria
- [ ] Progress modal shows current stage (loading model, transcribing, aligning)
- [ ] Determinate progress bar (0–100%) once progress data is available
- [ ] Elapsed time counter (HH:MM:SS)
- [ ] Note about first-run model loading time
- [ ] Cancel button to abort transcription

---

## US-T3: View transcription with speaker labels and timestamps

**As a** researcher,
**I want to** read the transcript with timestamps and speaker identification,
**so that** I can navigate the interview and know who said what.

### Acceptance Criteria
- [ ] Segment list shows timestamp, speaker badge (T1, T2, etc.), and text
- [ ] Speaker badges are color-coded with stable colors per speaker
- [ ] Speaker labels toggle on/off via "Talere" button
- [ ] Timestamps shown in HH:MM:SS or MM:SS format
- [ ] Scrollable list with word wrapping

---

## US-T4: Search within a transcript

**As a** researcher,
**I want to** search for specific words or phrases in the transcript,
**so that** I can find relevant passages quickly.

### Acceptance Criteria
- [ ] Search field available in transcript result view ("Søk i transkripsjon...")
- [ ] Case-insensitive filtering of segments
- [ ] Matching segments shown immediately as user types

---

## US-T5: Export a transcript

**As a** researcher,
**I want to** export the transcript in a standard format,
**so that** I can use it in other tools or share it with colleagues.

### Acceptance Criteria
- [ ] Export menu with two format options: Markdown and SRT
- [ ] Markdown format includes timestamps and speaker labels
- [ ] SRT format follows standard subtitle timecodes
- [ ] "Copy all" button for quick clipboard copy
- [ ] Per-segment copy button available

---

## US-T6: Add speaker identification (diarization)

**As a** researcher,
**I want to** identify which speaker said what,
**so that** I can distinguish between interviewer and participant in the transcript.

### Acceptance Criteria
- [ ] Diarization runs as a separate step after base transcription
- [ ] Requires HuggingFace token (configured in settings)
- [ ] Uses pyannote via no-transcribe CLI
- [ ] Progress tracked separately (`diarizationProgress`)
- [ ] Speaker labels added to existing segments
- [ ] Invalid HF token shows clear error (exit code 6)

---

## US-T7: Analyser transkripsjon fra editoren

**Updated:** 2026-04-17 — moved from recording detail view into the transcript editor (see decision log in [TRANSCRIPT_EDITOR.md § Design decisions](TRANSCRIPT_EDITOR.md#design-decisions))
**Implementation guide:** [TRANSCRIPT_EDITOR.md — AnalyseSectionView](TRANSCRIPT_EDITOR.md#analysesectionview-new)
**Depends on:** US-T11 (transcript editor must exist)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å kjøre en AI-generert analyse av transkripsjonen direkte fra transkripsjonseditoren,
**slik at** jeg raskt kan få et sammendrag av temaer og innhold etter at jeg har rettet og anonymisert teksten.

### Acceptance Criteria
- [ ] «Analyser transkripsjon»-seksjonen vises i sin egen **Analyse-fane** i transkripsjonseditoren — ikke i Transkripsjon-fanen
- [ ] Analyse-fanen fyller hele innholdsflaten (ingen sammenfolding, ingen toggle — fanebytte er navigasjonen)
- [ ] Avspillingskontrollene (play/pause/scrubber) er synlige og fungerer mens Analyse-fanen er aktiv
- [ ] «Analyser transkripsjon»-knapp er deaktivert med tooltip «Lagre endringer før analyse» dersom `isDirty == true`
- [ ] Knappen er deaktivert med tooltip «Ollama er ikke kjørende — start Ollama og prøv igjen» dersom Ollama ikke er tilgjengelig
- [ ] Analyse kjøres via Ollama lokalt (ingen sky) — standard modell: qwen3:8b (konfigurerbart i innstillinger)
- [ ] Ollama startes automatisk dersom det ikke kjører (venter opptil 20 sekunder)
- [ ] Framdrift vises med spinner og «Analyserer…»-label
- [ ] «Avbryt»-knapp kansellerer kjøringen og tilbakestiller tilstand til idle — ingen delvis resultatfil skrives
- [ ] 10-minutters timeout — overskridelse gir feil-tilstand med «Prøv igjen»-knapp
- [ ] Fullført analyse viser resultattekst inline i seksjonen
- [ ] Resultat lagres til `StorageLayout.analysisURL(id: recordingId)` (eller eksisterende analysesti)
- [ ] Metadata-sidecar oppdateres med `analysis.completedAt`
- [ ] Auditloggen skriver `transcriptAnalysed` med `recordingId`, modellnavn og tidsstempel
- [ ] «Kjør på nytt»-knapp tilgjengelig etter fullføring
- [ ] Analyse-seksjonen er **fjernet fra `RecordingDetailView`** — den eksisterer kun i editoren

### Out of scope
- Analyse av anonymisert variant kontra rå transkripsjon — alltid rå korrigert tekst (se open question 5 i TRANSCRIPT_EDITOR.md)
- Valg av analyseprompt i UI (modellnavn er konfigurerbart i innstillinger, ikke prompt)

---

## US-T8: Configure transcription settings

**As a** researcher,
**I want to** adjust transcription settings like model size and language,
**so that** I can balance quality vs. speed and support different Norwegian dialects.

### Acceptance Criteria
- [ ] Settings panel with: model size (tiny/base/medium/large), speaker count (1–10), verbatim mode, language (Bokmål/Nynorsk)
- [ ] Model download UI with size estimates per model
- [ ] HuggingFace token field for diarization
- [ ] Ollama model name field with status indicator
- [ ] All settings persist via `@AppStorage`

---

## US-T9: Install and update transcription engine

**As a** researcher,
**I want to** install the transcription engine from within the app,
**so that** I don't need to use the terminal or manage Python manually.

### Acceptance Criteria
- [ ] Installation status shown (installed/not installed, version)
- [ ] Install button creates venv and installs dependencies
- [ ] Update button upgrades to latest from GitHub
- [ ] Progress shown during installation (live pip output)
- [ ] Requirement noted: Python 3.10+ and internet access

---

## US-T10: Browse saved transcripts

**As a** researcher,
**I want to** see a list of all my transcripts in one place,
**so that** I can find and work with previous interviews.

### Acceptance Criteria
- [ ] "Transkripsjoner" tab shows all `.txt` files in `~/Desktop/tekstfiler/`
- [ ] Each entry shows: filename, date, size
- [ ] Icon indicates anonymization status (shield = anonymized, doc = not)
- [ ] Folder is monitored for changes (auto-refresh)
- [ ] Selecting a transcript shows detail panel with full text

---

## US-T11: Rett transkripsjonsfeil mens jeg lytter til opptaket

**Added:** 2026-04-17
**Implementation guide:** [TRANSCRIPT_EDITOR.md](TRANSCRIPT_EDITOR.md)
**Depends on:** US-T1 (transcription output), US-T3 (segment display), US-T6 (diarization — optional but enhances UX)
**Enables:** [US-FM-09](../file-management-teams-sync/USER_STORIES.md) upload flow (researchers edit before upload, per workflow decision 2026-04-17)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å lytte til lydopptaket og redigere transkripsjonen samtidig,
**slik at** jeg raskt kan finne og rette transkripsjonsfeil før jeg går videre til anonymisering eller opplasting.

### Acceptance Criteria
- [ ] Transkripsjonen vises segment-for-segment med tidsstempler og talerbadge (gjenbruker visuell stil fra US-T3)
- [ ] Standard avspillingskontroller: spill av, pause, søk i tidslinjen, avspillingshastighet (0.5×–2×)
- [ ] Ordet som spilles av akkurat nå framheves visuelt (karaoke-stil)
- [ ] Klikk på et ord eller segment spiller av **bare det segmentet** (fra det klikkede tidsstempelet til segmentslutt) og pauser automatisk ved segmentgrensen
- [ ] Etter auto-pause kan forskeren trykke «Spill av» for å fortsette kontinuerlig avspilling fra samme punkt
- [ ] Aktivt segment rulles automatisk inn i synsfeltet under avspilling
- [ ] Segmenttekst kan redigeres inline (dobbeltklikk eller «Rediger»-knapp)
- [ ] Endringer lagres i den kanoniske JSON-filen atomisk (temp-fil-og-gi-nytt-navn)
- [ ] `.txt`-eksporten regenereres automatisk fra redigert JSON
- [ ] Metadata-sidecar (`meta.json`) oppdateres med `transcript.lastEditedAt`
- [ ] Auditloggen skriver `transcriptEdited` ved hver lagret endring med `recordingId`, endrede segment-ID-er, og tidsstempel
- [ ] Ulagrede endringer vises med tydelig indikator i verktøylinjen
- [ ] Forsøk på å navigere bort med ulagrede endringer gir bekreftelsesdialog
- [ ] Avspilling pauser automatisk når et segment går inn i redigeringsmodus
- [ ] Verktøylinjen viser navnet på den tilknyttede lydfilen med en knapp («Vis opptak») som navigerer til opptaket i opptakslisten

### Out of scope
- Word-level timestamp re-alignment på redigert tekst (segmentgrenser forblir autoritative)
- Splitting og sammenslåing av segmenter (vurderes etter brukertilbakemelding)
- Tilbakestilling til original NB-Whisper-tekst per segment (mulig fremtidig tillegg — se [TRANSCRIPT_EDITOR.md § Open questions](TRANSCRIPT_EDITOR.md#open-questions))
- Redigering av anonymisert variant (se US-T12)

---

## US-T12: Anonymiser transkripsjon fra editoren

**Added:** 2026-04-17
**Implementation guide:** [TRANSCRIPT_EDITOR.md — AnonymizationSectionView](TRANSCRIPT_EDITOR.md#anonymizationsectionview-new)
**Depends on:** US-T11 (transcript editor must exist), US-T1 (transcription output)
**Related:** [AnonymizationService.swift](../../../Sources/AudioRecordingManager/AnonymizationService.swift)

**As a** brukerinnsiktsarbeider,
**ønsker jeg** å anonymisere transkripsjonen direkte fra transkripsjonseditoren etter at jeg er ferdig med å redigere,
**slik at** sensitiv informasjon fjernes fra den korrigerte teksten før opplasting, uten at jeg trenger å bytte fane eller verktøy.

### Acceptance Criteria

**Plassering og toggle**
- [ ] «Anonymisering»-seksjonen vises i **Transkripsjon-fanen**, over segmentlisten
- [ ] Seksjonen er **sammenfoldet som standard** — segmentlisten er synlig uten å scrolle ved åpning
- [ ] En header-rad med chevron-ikon (▶/▼) og «Anonymisering»-label er alltid synlig, uavhengig av om seksjonen er foldet ut
- [ ] Header-raden viser en kompakt statusbadge (✓ grønn / ⚠ rød / spinner) når anonymisering er fullført, feilet eller kjører — selv når seksjonen er sammenfoldet
- [ ] Klikk på header-raden ekspanderer eller folder seksjonen med animasjon

**Tilstand: idle**
- [ ] «Anonymiser transkripsjon»-knapp er synlig som primærknapp
- [ ] Knappen er **deaktivert** med tooltip «Lagre endringer før anonymisering» dersom `editor.isDirty == true`
- [ ] Info-tekst forklarer hva som fjernes: navn, telefonnumre, fødselsnumre/d-numre, steds- og organisasjonsnavn (via NER)

**Tilstand: running**
- [ ] Spinner + «Anonymiserer…»-label vises
- [ ] «NLP-modellen lastes ved første kjøring»-merknad vises som sekundær tekst
- [ ] «Avbryt»-knapp kansellerer `Task` og tilbakestiller til idle uten å skrive noen resultatfil

**Tilstand: completed**
- [ ] Hakemerke-ikon i `AppColors.success` + «Anonymisert [dato og klokkeslett]»-label
- [ ] Statistikksammendrag viser antall enheter fjernet per kategori (f.eks. «3 navn, 1 telefonnummer fjernet»)
- [ ] «Kjør på nytt»-knapp tilbakestiller til idle
- [ ] Ingen innebygd visning av anonymisert tekst (det er US-T13)

**Tilstand: failed**
- [ ] Advarsel-ikon + feilmelding inline
- [ ] «Prøv igjen»-knapp re-trigger anonymisering (tilbake til running)
- [ ] Eksisterende anonymisert fil (hvis den finnes fra en tidligere kjøring) er ikke slettet eller overskrevet ved feil

**Persistering og revisjon**
- [ ] Anonymisert tekst skrives atomisk til `StorageLayout.anonymizedTranscriptURL(id: recordingId)`
- [ ] Metadata-sidecar oppdateres med `anonymization.completedAt` og `anonymization.stats`
- [ ] Auditloggen skriver `transcriptAnonymized` med `recordingId`, stats-dict og tidsstempel
- [ ] Alle tre trinn (fil, sidecar, audit) må lykkes — delvis suksess betraktes som feil og vises som `failed`

**Generelt**
- [ ] Anonymisering kjøres alltid mot sist **lagrede** transkripsjonstekst — aldri mot in-memory-arbeidskopien
- [ ] `AnonymizationService` eksisterende i `RecordingDetailView` **flyttes** hit — ikke kopieres (duplikat kode er ikke akseptabelt)
- [ ] Alle brukervendte tekster er på bokmål

### Out of scope
- Anonymisering av selve lydopptaket (ingen `AudioAnonymizationService` eksisterer; dette er et mulig fremtidig story)
- Redigering av anonymisert transkripsjonstekst (US-T13)
- Automatisk anonymisering etter lagring (alltid en bevisst, manuell handling)

---

## Priority Order

| Priority | Story | Status |
|----------|-------|--------|
| 1 | US-T1 | Not started |
| 2 | US-T2 | Not started |
| 3 | US-T3 | Not started |
| 4 | US-T5 | Not started |
| 5 | US-T10 | Not started |
| 6 | US-T4 | Not started |
| 7 | US-T11 | Not started |
| 8 | US-T12 | Not started |
| 9 | US-T9 | Not started |
| 10 | US-T8 | Not started |
| 11 | US-T6 | Not started |
| 12 | US-T7 | Not started |
