# Dokumentasjonsindeks

Alle prosjektdokumenter med formål og sist verifisert mot kodebasen.

**Oppdatering:** Når du endrer et dokument, oppdater datoen i denne tabellen. Når du gjør kodeendringer, sjekk om noen dokumenter trenger oppdatering.

---

## Rotfiler

| Fil | Formål | Sist verifisert |
|-----|--------|----------------|
| [README.md](../README.md) | Brukerorientert setup-guide (norsk). Systemkrav, installasjon, hurtigstart. | 2026-05-26 |
| [AGENTS.md](../AGENTS.md) | AI-agentens onboarding. Leses automatisk av Claude Code, Copilot m.fl. ved oppstart. **Holder kodebasen i synk.** | 2026-05-26 |
| [CLAUDE.md](../CLAUDE.md) | Utvidet kontekst for Claude-sesjoner. Arkitekturstatus, ADR-pekere, konvensjoner. | 2026-05-26 |
| [BACKLOG.md](../BACKLOG.md) | Aktive og planlagte epics. Oppdateres ved sprint-start og når epics skifter status. | 2026-05-26 |
| [CHANGELOG.md](../CHANGELOG.md) | Versjonert endringslogg (Keep a Changelog-format). Oppdateres av release-skriptet. | 2026-05-26 |

---

## Tekniske spesifikasjoner

| Fil | Formål | Sist verifisert |
|-----|--------|----------------|
| [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](FILE_MANAGEMENT_AND_TEAMS_SYNC.md) | End-to-end fillivssyklus: lagring, opplasting til Teams/SharePoint, retensjon, compliance. Styrende spec for ADR-1014-arbeidet. | 2026-05-26 |
| [MODEL_SETUP.md](MODEL_SETUP.md) | Hvordan (re)generere de gitignorede CoreML-modellene (WhisperKit NB-Whisper-large, BERT NER) lokalt fra offentlige HuggingFace-checkpoints. Nødvendig etter en fersk klone. | 2026-08-20 |
| [no_anonymizer_v2_implementasjon.md](no_anonymizer_v2_implementasjon.md) | Referansedok for no-anonymizer-biblioteket (github.com/Fr35ch/no-anonymizer). Pipeline-arkitektur, lag, datafiler, JSON-kontrakt mot Clio. | 2026-05-26 |
| [TESTING.md](TESTING.md) | Testinfrastruktur: pytest (Python), pre-commit hooks, CI-workflows. Ingen Swift-enhetstester per i dag. | 2026-05-26 |
| [VERSIONING.md](VERSIONING.md) | SemVer-rutiner, release-skript, hvilke filer som må holdes i synk (inkl. MARKETING_VERSION i project.pbxproj). | 2026-05-26 |

---

## Beslutninger (ADR)

Arkitektoniske beslutninger under `decisions/adr/`. Bruk [malen](decisions/adr/TEMPLATE-FOR-ADR-FILES.md) for nye ADR-er.

| ADR | Tittel | Status |
|-----|--------|--------|
| [ADR-1014](decisions/adr/ADR-1014-file-storage-architecture-pivot.md) | File Storage Architecture Pivot | Aktiv — Phase 0 delvis implementert |
| [ADR-1007](decisions/adr/ADR-1007-nav-design-system-integration.md) | NAV Design System Integration | Superseded (Liquid Glass v1.4.0) |
| [ADR-1006](decisions/adr/ADR-1006-network-isolation-default.md) | Network Isolation Default | Superseded |
| [ADR-1004](decisions/adr/ADR-1004-pre-commit-hooks-quality-gate.md) | Pre-commit Hooks Quality Gate | Aktiv |
| [ADR-1013](decisions/adr/ADR-1013-optional-linear-integration.md) | Optional Linear Integration | Aktiv |

Øvrige ADR-er (0001–0002, 1001–1003, 1005, 1008–1012) er infrastruktur/agentiv-rammeverk fra Agentive Starter Kit og gjelder i begrenset grad for Clio-spesifikk utvikling.

---

## PRD / Brukerhistorier

| Mappe | Innhold | Status |
|-------|---------|--------|
| [prd/file-management-teams-sync/](prd/file-management-teams-sync/) | Brukerhistorier og Phase 0-oppgaveliste for lagrings-/opplastingsepicen | Aktiv — se PHASE_0_TASKS.md |
| [prd/transcription/](prd/transcription/) | Brukerhistorier for transkripsjon og transkripsjonseditoren | Delvis implementert |
| [prd/recording/](prd/recording/) | Brukerhistorier for opptak og opptaksdetaljvisning | Delvis implementert |
| [prd/anonymization/](prd/anonymization/) | Brukerhistorier for anonymisering | Delvis implementert |
| [prd/analysis/](prd/analysis/) | Maler og spørsmålsguider for brukerintervjuanalyse | Avventer intervjuer |

---

## Vedlikehold

**Når bør denne filen oppdateres?**
- Etter kodeendringer som påvirker arkitektur, lagring eller ekstern integrasjon
- Etter at et dokument er verifisert mot kodebasen
- Etter at en ny ADR eller PRD er lagt til

**Hvem verifiserer?**
`document-reviewer`-agenten kan kjøres manuelt (`/document-reviewer`) for å sjekke om dokumenter er i takt med kodebasen. Kjør gjerne før PR-merge på større endringer.
