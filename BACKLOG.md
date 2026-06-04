# Product Backlog

**Prosjekt:** Clio
**Sist oppdatert:** 2026-05-26

---

## Aktiv sprint

### 🔄 File Management Architecture Pivot — Phase 0

**Epic:** File Management & Teams Sync
**Beslutning:** [ADR-1014](docs/decisions/adr/ADR-1014-file-storage-architecture-pivot.md)
**Spec:** [docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md](docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md)
**Oppgaveliste:** [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](docs/prd/file-management-teams-sync/PHASE_0_TASKS.md)

Lagring flyttes fra Desktop til `~/Library/Application Support/Clio/` med UUID-navngitte opptaksmapper og metadata-sidecars. Audit-logg er allerede på plass. Phase 1 (Graph API-opplasting til Teams/SharePoint) er blokkert av Azure AD-registrering.

**Gjenstående oppgaver (se PHASE_0_TASKS.md for detaljer):**
- ❌ **D2** TranscriptionService skriver transkripsjon til opptaksmappen og oppdaterer sidecar
- ❌ **D5** Alle `URL(fileURLWithPath: recording.path)` erstattes med `StorageLayout`-kall
- ❌ **D6** `AudioFileManager`-klassen slettes
- ❌ **E1–E3** Desktop-egress fjernes (`.desktopDirectory`, Reveal in Finder, NSSharingService)
- ❌ **0F** 30-dagers lokal oppbevaring med advarsler og automatisk sletting

**Ekstern avhengighet:**
- MDM-synkutelukkelse av `~/Library/Application Support/Clio/` — blokkerer ship
- Azure AD / Entra ID app-registrering — NAV IT (lang leveringstid, blokkerer Phase 1)

---

## Phase 1 — Opplasting via Graph API

**Status:** Backlog — blokkert av Azure AD-registrering
**Avhengig av:** Phase 0 ferdig + MDM-utelukkelse bekreftet

- Direkte opplasting til Teams/SharePoint via Microsoft Graph API
- Per-artefakt automatisk opplasting når opptaket er i stabil tilstand
- Prosjektkonsept i UI (mappestruktur på Teams per prosjekt)
- Destinasjonsvelger — avventer brukerintervjuer (produkteier)

---

## Phase 2 — Forskerarbeidsflyt (avventer discovery)

**Status:** Backlog — avventer brukerintervjuer
**Avhengig av:** Phase 1 ferdig + intervjufunn fra produkteier

Omfang ikke fastsatt. Kandidater:
- Prosjektoversikt og arkivfunksjonalitet
- Eksportformater (RTF, DOCX)
- Forbedret anonymiserings-UX

---

## Teknisk gjeld

- `main.swift` er fortsatt svært stor — inkrementell oppsplitting pågår
- `RecordingExpiryManager` er implementert men bevisst deaktivert (ingen migrasjonsstrategi for eksisterende opptak ennå)
