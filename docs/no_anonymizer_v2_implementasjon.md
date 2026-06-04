# no-anonymizer: Implementasjonsreferanse

**Status:** v0.5.0 implementert
**Repo:** github.com/Fr35ch/no-anonymizer
**Konsument:** Clio (macOS) via subprocess bridge (`Resources/anonymize_bridge.py`)

> Dette dokumentet beskriver den faktiske implementasjonen. Det opprinnelige dokumentet beskrev en planlagt v2-arkitektur som aldri ble realisert som beskrevet — den faktiske implementasjonen er annerledes, men oppnår de samme målene med en enklere tilnærming.

---

## 1. Kontekst

`no-anonymizer` er et Python-bibliotek som anonymiserer transkripsjoner av brukerintervjuer for NAV. Det kalles som subprosess fra Clio (Swift/macOS) via `Foundation.Process`, og kommuniserer via temp-filer med JSON-output.

---

## 2. Arkitektur

Pipeline i `anonymizer.anonymize()`:

```
0. normalize_text()         — ALL-CAPS ord (4+ tegn) → Title Case
1. regex_patterns.detect()  — telefon, e-post, fødselsnummer, D-nummer, postboks
2. ssb_names.detect()       — SSB-navneliste (fornavn + etternavn, case-insensitive)
3. bert_ner.detect()        — NbAiLab/nb-bert-base-ner (PER→[NAVN], LOC/GPE→[STED], ORG telles men redigeres ikke)
4. steder.detect()          — Kartverket stedsnavn
5. address_lookup.detect()  — Kartverket API-verifisering av adresser
6. _merge_spans()           — deduplisering og overlapp-løsning etter prioritet
7. ambiguity.filter_ambiguous() — kontekstuell filter for tvetydige norske navn
8. _apply_exceptions()      — unntak fra unntak.txt
9. _build_result()          — erstatt spans og bygg output
```

### Prioritetsrekkefølge (overlapp)

```
0: regex (telefon, e-post, fnr, D-nummer) — høyest
1: SSB-navn, adresser, Kartverket-steder
2: NER (ORG, STED)                        — lavest
```

Innen samme prioritetsnivå vinner lengste match.

---

## 3. Deteksjonslag

### regex_patterns

Strukturert PII med regex:
- Telefonnummer (norske formater: +47, 0047, bare 8-siffer)
- E-postadresser
- Fødselsnummer (11 siffer, første siffer 0-3)
- D-nummer (11 siffer, første siffer 4-7)
- Postboks-adresser

Ingen sjekksum-validering — bevisst valg for å over-redigere fremfor å under-redigere.

### ssb_names

- Laster `data/ssb_fornavn.txt` og `data/ssb_etternavn.txt`
- Case-insensitive matching (norsk `casefold()`)
- Håndterer bindestreksnavn: `Olav-Martin` rediges hvis *noen* del er et kjent navn

### bert_ner

- Modell: `NbAiLab/nb-bert-base-ner` (~450 MB, lastes fra HuggingFace ved første kjøring)
- `aggregation_strategy="simple"`
- Mapping: `PER → [NAVN]`, `LOC/GPE → [STED]`, `ORG → telles, ikke redigert`
- Lange inputs chunkes ved setningsgrenser (maks 480 BERT-tokens per chunk, pga 512-token limit i checkpointet)
- Returnerer `score` per entitet (brukes av ambiguity-filteret)

### ambiguity.filter_ambiguous

Kontekstuell filter for tvetydige norske fornavn som også er vanlige ord (Vår, Jo, Dag, Per, Mai, Bjørn, Tor, Liv, Hans, ...).

**`name_strictness`-parameter:**
- `strict` — hopp over filteret (historisk atferd, alle treff rediges)
- `balanced` (standard) — regler nedenfor
- `loose` — krever sterkere støtte

**Regler i `balanced`-modus:**
1. Ikke kapitalisert i kildeteksten → FJERN span
2. Setningsstart → kapitaliseringen er uinformativ; behold kun ved:
   a. Kapitalisert SSB-listenabo (forrige/neste token), eller
   b. Navn-introduserende forgjenger (hr., fru, hei, snakket med...), eller
   c. Rapporteringsverb-etterfølger (sa, spurte, svarte...)
3. BERT-score ≥ 0.95 → BEHOLD uansett
4. Ellers → BEHOLD (mid-setnings-kapitalisering er sterk indikasjon)

### address_lookup

Verifiserer NER STED-spans som inneholder siffer mot Kartverket-API. Kan skrus av med `use_address_lookup=False`.

### steder

Kartverket stedsnavn fra `data/kartverket_steder.txt`.

---

## 4. Datafiler

```
data/
├── ssb_fornavn.txt         — ett navn per linje, UTF-8
├── ssb_etternavn.txt       — ett navn per linje, UTF-8
├── kartverket_steder.txt   — norske stedsnavn
src/no_anonymizer/patterns/
├── ambiguous_names.txt     — tvetydige tokens (Vår, Jo, Per, ...)
└── unntak.txt              — globale unntak (falske positive som alltid beholdes)
```

---

## 5. Filstruktur

```
src/no_anonymizer/
├── anonymizer.py           — pipeline-orkestrator
├── exceptions.py           — unntak-lastning og matching
├── models.py               — Redaction, AnonymizationResult dataklasser
├── preprocessor.py         — CAPS-normalisering
├── text_context.py         — setningsgrense-detektor, kontekst-hjelpere
├── layers/
│   ├── address_lookup.py   — Kartverket API
│   ├── ambiguity.py        — kontekstuell filter for tvetydige navn
│   ├── bert_ner.py         — NbAiLab BERT NER
│   ├── regex_patterns.py   — strukturert PII
│   ├── ssb_names.py        — SSB-navneliste
│   └── steder.py           — Kartverket stedsnavn
└── updater/
    └── ssb_updater.py      — oppdater SSB-datafiler fra ssb.no
```

---

## 6. JSON-output-kontrakt mot Clio

```json
{
  "anonymized_text": "...",
  "redactions": [
    {
      "original_position": 142,
      "length": 5,
      "category": "NAVN",
      "replacement": "[NAVN]",
      "score": 0.99
    }
  ],
  "stats": { "NAVN": 3, "TELEFON": 1 },
  "processing_time_ms": 1240.5,
  "address_lookups_performed": 2,
  "network_available": true
}
```

Clio (`AnonymizationResult` i Swift) håndterer også valgfrie v2-felter (`flagged_for_review`, `statistics`, `audit_log_path`, `version`) for fremtidig kompatibilitet, men disse emitteres ikke av den nåværende Python-implementasjonen.

---

## 7. Installasjon og kjøring

```bash
# Installer med NER-avhengigheter
pip install "no-anonymizer[ner]"

# Eller i dev-modus
cd ~/Github/no-anonymizer
python -m venv .venv
source .venv/bin/activate
pip install -e ".[ner,dev]"

# Clio bruker .venv automatisk hvis den finnes på:
# ~/Github/no-anonymizer/.venv/bin/python3
```

---

## 8. Tester

```bash
pytest -m "not slow"   # raske enhetstester
pytest                 # alle tester inkl. integrasjonstester
```

Testene dekker regex-mønstre, SSB-oppslag, ambiguity-filter, adresseoppslag, og full pipeline.

---

## 9. Etter denne versjonen (ikke i scope)

- Tre-veis beslutningsoutput (redact/flag/keep) til Clio UI
- Pseudonymisering med konsistent mapping
- Cross-token resonnering (konsistent håndtering av samme navn nevnt flere ganger)
- Utvidet entitetstype (datoer, beløp som indirekte identifikatorer)


---

## 1. Kontekst

`no-anonymizer` er et Python-bibliotek som anonymiserer transkripsjoner av brukerintervjuer for Nav. Det kalles som subprosess fra ARM (Swift/macOS) via `Foundation.Process`, og kommuniserer over stdin/stdout med JSON.

Dagens implementasjon bruker SpaCy NER (`nb_core_news_lg`) med SSB-navnelister, Kartverket-adresseoppslag, og regex for norske identifikatorer (fødselsnummer, D-nummer, telefon, e-post). CAPS-normalisering kjøres som preprosessering før NER for å unngå falske positive på all-caps-tekst.

**Problemet vi løser:** SpaCy markerer mange homografer som navn — norske egennavn som også er vanlige ord. «Bjørn», «Per», «Mai», «Tor», «Even», «Mona», «Sol», «Tone», «Vår» blir redigert uavhengig av om de faktisk brukes som navn i konteksten. Resultatet er overredaksjon som svekker transkripsjonens analytiske verdi i etterfølgende innsiktsarbeid.

**Den arkitektoniske endringen:** Gå fra binær NER-beslutning per token til evidensbasert beslutning der hver kandidat akkumulerer signaler før redaksjon.

---

## 2. Mål for v2.0

1. Implementere firelagsmodell: leksikonoppslag → kontekstuell evidens → skåraggregering → trekantbeslutning
2. Splitte navnelisten i tre buckets: entydige navn, tvetydige tokens, vernede vanlige ord
3. Innføre flagging av tvilstilfeller for menneskelig gjennomgang i ARM UI
4. Strukturert auditlogg per beslutning med signaler og endelig skår
5. Statiske vekter i konfigurasjonsfil (ingen læring i denne versjonen)
6. Bakoverkompatibel JSON-output mot ARM med utvidet metadata

## 3. Ikke-mål

- Maskinlæring eller dynamiske vekter
- UI-arbeid i Clio (kun output-kontrakt)
- Endringer i CAPS-normalisering, regex-deteksjon eller adresseoppslag
- ORG-entiteter — behandles fortsatt som logget men ikke redigert

---

## 4. Arkitektur

Pipelinen kjører i fire lag per token-kandidat fra NER:

### Lag 1: Leksikonoppslag
SSB-navnelistene splittes i tre kategorier som hver gir en startskår:

| Kategori | Innhold | Startskår |
|---|---|---|
| Entydig navn | Navn som praktisk talt aldri opptrer som vanlige ord (Sigurd, Aslaug, Magnus, Hovde) | +0.7 |
| Tvetydig token | Homografer som finnes både som navn og som vanlige ord (Bjørn, Per, Mai, Tor, Even, Tone, Mona, Sol, Vår, Frida, Linn) | 0.0 |
| Vernet vanlig ord | Ord SpaCy ofte feilflagger (måneder, ukedager, dyrenavn med homograf, idiomatiske komponenter som "per") | -0.5 |
| Ikke i leksikon | Token er ikke listet | 0.0 |

Splittingen gjøres som datafiler i `no_anonymizer/lexicon/data/`. Klassifiseringen baseres på frekvensanalyse: et navn regnes som entydig hvis navnefrekvensen i SSB-data dominerer sterkt over forekomster som vanlig ord. Tvetydige tokens identifiseres ved kryssoppslag mot norsk ordliste.

### Lag 2: Kontekstuell evidens
For **alle** tokens — også de fra "entydig navn"-bucketen — samles signaler som justerer skåren. Dette håndterer kanten der et "entydig" navn brukes ironisk, som referanse til en kjent person, eller som del av et stedsnavn.

**Positive signaler (peker mot navn):**

| Signal | Vekt | Beskrivelse |
|---|---|---|
| `pos_propn` | +0.2 | SpaCy POS-tag er PROPN |
| `title_before` | +0.4 | Foregående token er tittel (herr, fru, dr., professor, advokat) |
| `last_name_after` | +0.3 | Etterfølgende token er kapitalisert og finnes i etternavnsliste |
| `identity_verb_context` | +0.4 | Token er subjekt/objekt for "heter", "kalles", "navnet er" |
| `vocative_pattern` | +0.3 | Mønster: "hei [X]", "takk [X]", "[X], kan du ..." |
| `mention_intro` | +0.3 | Foregående: "en kollega", "en person", "en som heter" |

**Negative signaler (peker mot vanlig ord):**

| Signal | Vekt | Beskrivelse |
|---|---|---|
| `pos_noun` | -0.3 | SpaCy POS-tag er NOUN |
| `pos_verb` | -0.5 | SpaCy POS-tag er VERB |
| `idiom_match` | -0.7 | Token er del av kjent idiom ("per stykk", "per definisjon", "per i dag") |
| `temporal_context` | -0.5 | Etterfølger temporal preposisjon ("i mai", "om våren", "før sol") |
| `sentence_start` | -0.1 | Token står først i setningen — kapitalisering ikke informativ |

Alle signaler implementeres som rene funksjoner som returnerer `bool` gitt token og kontekst (forrige/neste tokens, POS-tags, dependency parse fra SpaCy).

### Lag 3: Skåraggregering
```
final_score = lexicon_start_score + Σ(triggered_signal_weights)
```

Ingen normalisering, ingen sigmoid. Vektene er kalibrert mot tersklene direkte.

### Lag 4: Trekantbeslutning

| Skår | Beslutning |
|---|---|
| `≥ 0.5` | `redact` — redigeres automatisk |
| `0.0 ≤ skår < 0.5` | `flag` — markeres for menneskelig gjennomgang i ARM |
| `< 0.0` | `keep` — beholdes |

Standardatferd ved usikkerhet er fortsatt redaksjon: tokens som er flagget men ikke aktivt godkjent av bruker i ARM, redigeres ved eksport.

---

## 5. Datastrukturer

### Token-kandidat (intern)
```python
@dataclass
class TokenCandidate:
    text: str
    start: int  # tegnposisjon i transkripsjon
    end: int
    ner_label: str  # PER, LOC, ORG
    pos_tag: str
    dep_relation: str
    sentence_id: int
    sentence_position: int  # 0 = setningsstart
    prev_token: Optional[str]
    next_token: Optional[str]
```

### Beslutning (output)
```python
@dataclass
class TokenDecision:
    token: TokenCandidate
    lexicon_bucket: Literal["unambiguous_name", "ambiguous", "protected_common", "unknown"]
    starting_score: float
    triggered_signals: list[SignalHit]  # navn + vekt
    final_score: float
    decision: Literal["redact", "flag", "keep"]
    decision_reason: str  # menneskelig lesbar oppsummering
```

### Auditlogg-entry
```python
@dataclass
class AuditEntry:
    timestamp: str  # ISO 8601
    transcript_id: str
    token_text: str
    token_position: tuple[int, int]
    ner_label: str
    lexicon_bucket: str
    starting_score: float
    signals: list[dict]  # [{"name": "pos_propn", "weight": 0.2}, ...]
    final_score: float
    decision: str
```

---

## 6. JSON-kontrakt mot ARM

Output utvides bakoverkompatibelt. Eksisterende felter beholdes, nye legges til:

```json
{
  "version": "2.0",
  "anonymized_text": "...",
  "redactions": [
    {
      "original": "Bjørn",
      "replacement": "[NAVN]",
      "start": 142,
      "end": 147,
      "type": "PER",
      "decision": "redact",
      "score": 0.6,
      "bucket": "ambiguous"
    }
  ],
  "flagged_for_review": [
    {
      "original": "Mai",
      "start": 230,
      "end": 233,
      "type": "PER",
      "score": 0.2,
      "bucket": "ambiguous",
      "context_snippet": "møttes i mai 2026",
      "signals_summary": "temporal_context (-0.5), pos_propn (+0.2)"
    }
  ],
  "statistics": {
    "total_candidates": 47,
    "redacted": 31,
    "flagged": 5,
    "kept": 11,
    "by_bucket": { "unambiguous_name": 18, "ambiguous": 22, "protected_common": 4, "unknown": 3 }
  },
  "audit_log_path": "/path/to/audit_2026-05-12.jsonl"
}
```

`flagged_for_review` er det nye feltet ARM trenger for å vise tvilssonen i UI. `context_snippet` skal være ±30 tegn rundt token for at innsiktsmedarbeideren skal kunne ta avgjørelsen uten å åpne hele transkripsjonen.

---

## 7. Filstruktur

```
no_anonymizer/
├── __init__.py
├── pipeline.py                    # Hovedorkestrering — kalt fra CLI
├── cli.py                         # Eksisterende — utvides med v2-flagg
├── preprocessing/
│   ├── caps_normalizer.py         # Eksisterende, uendret
│   └── ...
├── ner/
│   └── spacy_runner.py            # Eksisterende, uendret
├── lexicon/                       # NY
│   ├── __init__.py
│   ├── lookup.py                  # Trekategorisk oppslag
│   └── data/
│       ├── unambiguous_names.json
│       ├── ambiguous_tokens.json
│       └── protected_common_words.json
├── evidence/                      # NY
│   ├── __init__.py
│   ├── collectors.py              # Signal-funksjoner
│   ├── patterns.py                # Norske språkmønstre, idiomliste
│   └── weights.py                 # Statisk vektkonfigurasjon
├── decision/                      # NY
│   ├── __init__.py
│   ├── aggregator.py              # Skåraggregering
│   └── thresholds.py              # Beslutningsterskler
├── audit/                         # NY
│   ├── __init__.py
│   └── logger.py                  # JSONL audit-skriving
└── regex/
    └── ...                        # Eksisterende, uendret
```

---

## 8. Implementasjonsrekkefølge

Bygges i denne rekkefølgen for å holde testbart i hvert steg:

1. **Datafiler først.** Splitt eksisterende SSB-liste i tre buckets. Bygg `unambiguous_names.json`, `ambiguous_tokens.json`, `protected_common_words.json`. Skriv et enkelt skript som regenererer disse fra kildedata — det skal være reproduserbart, ikke håndvedlikeholdt.

2. **`lexicon/lookup.py`.** Implementer trekategorisk oppslag. Returnerer `(bucket, starting_score)` for et gitt token. Test med enhetstester mot kjente eksempler.

3. **`evidence/patterns.py`.** Definer idiomliste, tittelliste, etternavnsliste, identitetsverbliste, temporalpreposisjonsliste. Disse skal være eksplisitte, ikke hardkodet i collector-koden.

4. **`evidence/collectors.py`.** Implementer hver signal-funksjon som en ren funksjon: `def pos_propn(candidate: TokenCandidate, context: SentenceContext) -> bool`. Hver funksjon skal være testbar isolert.

5. **`evidence/weights.py`.** Statisk dictionary fra signalnavn til vekt. Inkluder en `load_weights()`-funksjon som leser fra YAML/JSON så vekter kan justeres uten kodeendring.

6. **`decision/aggregator.py` og `thresholds.py`.** Summer signaler, anvend terskler, returner `TokenDecision`.

7. **`audit/logger.py`.** JSONL-format, én linje per beslutning. Loggfilen lagres med tidsstempel i filnavnet, returneres i output-JSON.

8. **`pipeline.py`-integrasjon.** Bind sammen eksisterende NER-output med ny beslutningspipeline. Sørg for at regex-deteksjoner (fødselsnummer, telefon, e-post) går utenom det nye laget — de er deterministiske og skal alltid redigeres.

9. **JSON-output v2.** Utvid `redactions`-array, legg til `flagged_for_review`, `statistics`, `audit_log_path`.

10. **CLI-flagg.** Legg til `--strict-mode` (bypass flagging, redigér alt over `keep`-terskel) for tilfeller der ARM eller andre konsumenter ikke kan håndtere flagged-feltet.

---

## 9. Tester

### Enhetstester
- Hver signal-collector mot et sett kjente eksempelsetninger
- Leksikonoppslag mot hvert bucket
- Skåraggregering med kjente signal-kombinasjoner
- Beslutningsterskler ved nøyaktig grenseverdier

### Integrasjonstester
Bygg en testkorpus med 30–50 håndannoterte setninger som dekker:

- Entydige navn i normal kontekst ("Sigurd ringte i dag") → `redact`
- Homografer som navn ("min kollega Bjørn sa") → `redact`
- Homografer som vanlige ord ("vi så en bjørn i skogen") → `keep`
- Idiomer ("ti kroner per stykk") → `keep`
- Temporal kontekst ("møtet er i mai") → `keep`
- Tvilstilfeller der konteksten er svak ("Mai sa noe") → `flag`
- Setningsstart-tilfeller ("Per gikk hjem") → må fungere via andre signaler
- Falske negative-sjekk: navn som beholdes ved feil må fanges

Korpus lagres som `tests/fixtures/disambiguation_corpus.jsonl` med hver linje:
```json
{"text": "...", "target_token": "Bjørn", "expected_decision": "keep", "rationale": "..."}
```

### Regresjonstester
- Eksisterende ARM-testtranskripsjoner må produsere lik eller bedre output (færre falske positive, ingen nye falske negative).

---

## 10. Akseptansekriterier

1. På testkorpuset: minst 90 % korrekt beslutning på tvetydige tokens (sammenlignet med dagens implementasjon som typisk redigerer alle).
2. Antall `redact`-beslutninger på vernede vanlige ord skal være 0 i normale tilfeller.
3. JSON-output v2 validerer mot schema og kan parses av eksisterende ARM-kode (bakoverkompatibilitet).
4. Auditlogg skrives for hver beslutning, kan parses som JSONL, inneholder alle påkrevde felter.
5. CLI-kommando `no-anonymizer --version` returnerer `2.0.0`.
6. Pipeline-kjøretid øker med maks 20 % sammenlignet med v1 (signal-collection er rask).
7. Alle enhetstester passerer, alle integrasjonstester passerer.

---

## 11. Vektkalibrering

Vektene i tabellene over er **utgangspunkt**, ikke endelige verdier. Etter første implementasjon kjøres testkorpuset, og vektene justeres til akseptansekriteriene møtes. Justeringen skjer i `evidence/weights.py` (YAML-loaded), ikke i kode. Dokumenter hver justering i `CHANGELOG.md` med begrunnelse.

---

## 12. Etter denne versjonen (ikke i scope nå)

- Læring av vekter fra ARM-brukerens flagg-godkjenninger
- Utvidet entitetstype (datoer, sykdomstilstander, økonomiske beløp som indirekte identifikatorer)
- Cross-token resonnering (samme navn nevnt flere ganger → konsistent beslutning)
- Pseudonymisering med konsistent mapping for forskning-rerunning

---

**Kjør implementasjonen i rekkefølgen ovenfor. Stopp etter hvert steg og verifiser med tester før neste lag bygges. Hvis du er usikker på en avgrensning, prioriter konservativt: heller flagge enn å beholde, heller beholde enn å redigere uten evidens.**
