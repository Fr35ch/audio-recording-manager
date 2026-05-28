# Analyse-seksjonen — arbeidsplan og implementasjonsnotater

**Scope:** `Sources/Clio/Analysis/` + `docs/prd/analysis/`
**Sist oppdatert:** 2026-05-28

---

## Arkitekturoversikt

### Kildefiler

| Fil | Ansvar |
|-----|--------|
| `AnalysisComposerView.swift` | Kolonne 3 i Analyser-fanen; transkripsjonsvelger, mal-dropdown, kjøreorkestrering |
| `AnalysisListColumn.swift` | Kolonne 2; liste over alle lagrede analyser |
| `AnalysisDetailColumn.swift` | Kolonne 3-router; velger mellom composer og resultatvisning |
| `AnalysisModels.swift` | `Analysis` (manifest), `AnalysisSource`, `AnalysisKind`, `AnalysisStatus` |
| `AnalysisResultDetailView.swift` | Resultatvisning; header-strip + faner (alt/temaer/behov/mønstre) + kildeskjerm |
| `AnalysisResultParser.swift` | Parser råmarkdown fra LLM til `AnalysisResult`-felter |
| `AnalysisStore.swift` | Lese/skrive manifest.json og result.json under `<dataRoot>/analyses/<id>/` |
| `OllamaAnalysisService.swift` | HTTP-klient mot `localhost:11434/api/generate`; `stream: false` per nå |
| `PromptTemplate.swift` | `PromptTemplate`-modell med id, versjon, mal-body, `appliesTo`-kind |
| `PromptTemplateLibrary.swift` | Singleton; leverer innebygde + brukerdefinerte maler |
| `TranscriptHash.swift` | SHA-256 av transkripsjonstekst; brukes til å oppdage drift |

### Dataflyt — kjøring av analyse

```
AnalysisComposerView
  → renders prompt fra PromptTemplateLibrary + researchContext + transcript(er)
  → skriver manifest.json (status: pending) via AnalysisStore
  → kaller OllamaAnalysisService.analyze(prompt:model:)
      → POST localhost:11434/api/generate { stream: false }
      → venter på fullstendig svar
      → returnerer rawMarkdown
  → kaller AnalysisResultParser.parse(rawMarkdown:)
  → skriver result.json via AnalysisStore
  → oppdaterer manifest til status: completed
  → flipper selectedAnalysisId → AnalysisResultDetailView viser resultatet
```

### Lagringsformat

```
~/Library/Application Support/Clio/analyses/<uuid>/
    manifest.json    ← Analysis-struct (schemaVersion, id, title, kind, sources, model, status, ...)
    result.json      ← AnalysisResult (rawMarkdown, keyThemes, keyQuotes, identifiedNeeds, opportunities, summary)
    prompt.txt       ← literal prompt sendt til LLM
```

---

## Åpne todos

### 1. Strømming fra Ollama `stream: false` → `stream: true`

**Problem:** `OllamaAnalysisService` bruker `stream: false`. En 4B-modell bruker 2–5 minutter på å generere et fullt svar uten å sende noe tilbake. UI-et ser fryst ut — brukeren ser bare en spinner uten fremgang.

**Ønsket oppførsel:** tokens strømmes inn og vises som fremgangstekst i `AnalysisComposerView`. Etter fullføring parses det endelige svaret som nå.

**Implementasjonsnotater:**
- Ollama returnerer NDJSON-linjer når `stream: true`; hver linje er `{"model":"...","response":"<token>","done":false}` til siste melding med `"done":true`.
- `OllamaAnalysisService.analyze()` bør ta en `onToken: ((String) -> Void)?`-closure eller byttes til `AsyncStream<String>`.
- `AnalysisComposerView` har allerede `runState: ComposerRunState` med `.running(progressText:)` — oppdater `progressText` inkrementelt.
- Sluttparsing (til `AnalysisResult`) kan skje på akkumulert tekst etter at `done: true` er mottatt.

---

### 2. Markdown-rendering av analyseresultat

**Problem:** `AnalysisResultDetailView` bruker strukturerte seksjoner fra `AnalysisResult` (keyThemes, keyQuotes, osv.), men `rawMarkdown`-feltet vises per nå som ren tekst. Modellresponsen inneholder overskrifter, fet tekst og punktlister som ikke formateres.

**Ønsket oppførsel:** Markdown rendres korrekt — overskrifter, fet tekst, kursiv og punktlister er lesbare.

**Implementasjonsnotater:**
- SwiftUI støtter `Text(try! AttributedString(markdown: str))` for enkel inline markdown.
- For fullstendige seksjoner med overskrifter (`## Sammendrag` osv.) trengs en `ScrollView` med tekst-rendering eller en tredjepartsløsning.
- Alternativt: parseren (`AnalysisResultParser`) fjerner markdown-syntaks og returnerer ren tekst per seksjon — enklere, men mister formatering.
- Vurder `swift-markdown-ui`-pakken som er et naturlig valg for macOS SwiftUI.

---

### 3. UX-gjennomgang — resultatvisning

**Problem:** Brukeren noterte at resultatvisningen har dårlig lesbarhet og layout. Generelt trenger seksjonen en UX-pass.

**Prioriterte forbedringer:**
- Seksjonstitler og kortlayout ser ikke ferdig ut
- Fane-navigasjonen (alt/temaer/behov/mønstre) er ikke tydelig nok
- Tomt-tilstand for mislykket eller manglende analyse trenger mer veiledning
- "Kopier"-knappen bør gi visuell feedback (checkmark → tilbake)
- Eksport-funksjon mangler (knappen finnes, logikk ikke implementert?)
- "Ny iterasjon" bør forhåndsutfylle `researchContext` fra forrige kjøring

---

### 4. UX-gjennomgang — composer

**Problem:** Composer-visningen mangler konteksthjelp og kjøreindikatorer.

**Prioriterte forbedringer:**
- `researchContext`-feltet trenger placeholder med eksempel
- Maldropdownen bør vise en kort beskrivelse av hva malen gjør
- Valgte opptak bør vise antall ord / varighet slik at forsker kan vurdere omfang
- Løpende analyse bør vise medgått tid (sekundsvisning under spinner)

---

### 5. NAV-delt HuggingFace-token (lav prioritet)

**Problem:** Brukeren spørte om en delt NAV-organisasjonstoken kunne bundles for å unngå at hver forsker trenger en personlig HF-konto.

**Vurdering:**
- `NbAiLab/borealis-4b-gguf` er `gated: auto` — etter lisensgodkjenning på huggingface.co fungerer direkte nedlasting uten token.
- En delt token kan gi enklere onboarding, men krever rotasjonsstrategi og øker angrepsflaten hvis tokenet lekker.
- Ikke implementert; avventer avklaring fra produkteier.

---

## Kjente tekniske begrensninger

| Begrensning | Påvirkning | Workaround |
|-------------|-----------|-----------|
| `stream: false` i OllamaAnalysisService | UI ser fryst ut under analyse | Se todo #1 |
| `AnalysisResultParser` forventer eksakte seksjonsoverskrifter | Feil i LLM-output gir tomme seksjoner | Parser loggfører manglende seksjoner; `rawMarkdown` alltid lagret |
| Borealis 4B-modell krever 16 GB RAM + Apple Silicon | Kjører ikke på eldre/billige maskiner | `DependencyManager` verifiserer ved oppstart |
| `OllamaManager.downloadGGUFAndCreate()` bruker `curl` + `ollama create` | Avhengig av Homebrew curl og at GGUF-URL på HuggingFace ikke endres | Ingen automatisk versjonssporing |

---

## Beslutninger (append-only)

### 2026-05-27 — Borealis-integrasjon fullført end-to-end

- `ollama pull hf.co/...` er ødelagt i alle nåværende Ollama-versjoner (realm host-mismatch). Workaround: direkte GGUF-nedlasting via `curl` + `ollama create`.
- `LLMModel.ollamaId` returnerer `"borealis-4b"` (lokalt registrert navn), ikke HF-URLen. Alle Ollama API-kall bruker `ollamaId`; `rawValue` er kun for UserDefaults-lagring.
- HuggingFace-token fjernet — `gated: auto`-modeller fungerer etter lisensgodkjenning på nettstedet.
- Ollama 0.24.0 er nåværende siste versjon (versjonsskjema er 0.1→0.24, ikke semver minor).

### 2026-05-27 — Anonymiseringsskript nå bundles i app

- `Resources/anonymize_bridge.py`, `ssb_fornavn.txt` og `ssb_etternavn.txt` lagt til som bundle-ressurser i `project.yml`.
- Fikser "Anonymiseringsskript ikke funnet i appbunten"-feilen (`AnonymizationService.bridgeScriptURL()` søkte via `Bundle.main.url(forResource:)` men filen var aldri inkludert i bygget).

---

## Fremtidige ideer (ikke committet)

- Støtte for `stream: true` med token-for-token-fremvising og avbrytbar kjøring
- Analyse-historikk med sammenligning (samme transkripsjon, ulike maler/modeller)
- Export til PDF/Word fra resultatvisningen
- Gruppeanalyse-maler: `group-cross-cutting-patterns`, `opportunity-map`, `pain-points-and-frustrations` er definert i `templates/`-mappen men ikke testet
- Brukerdefinerbare maler (JSON under `<dataRoot>/analyses/_templates/`) — infrastrukturen finnes i `PromptTemplateLibrary`, men UI for å opprette/redigere maler mangler
