# Clio

macOS-app for opptak, transkripsjon, talerutskilling og analyse av brukerintervjuer.
Utviklet for NAV Arbeids- og velferdsdirektoratet.

**Versjon**: 1.4.1 · **Krever**: macOS 14 Sonoma · Apple Silicon · 16 GB RAM · 30 GB ledig disk

---

## Funksjonalitet

| Steg | Funksjon | Avhengighet |
|------|----------|-------------|
| 🎙️ Opptak | Innspilling direkte i appen | Mikrofontilgang |
| 📝 Transkripsjon | Norsk tale-til-tekst via NB-Whisper | Python 3.10+ · no-transcribe |
| 👥 Talerutskilling | Identifiser hvem som snakker| Hardware RØDE Micro Go
| 🔒 Anonymisering | Fjern navn og personnummer | no-anonymizer |

---
**NB-Whisper-modell** lastes ned automatisk første gang du transkriberer.
Du kan forhåndslaste den via Innstillinger → Transkripsjon → Last ned modell.

| Modell | Størrelse | Nedlastningstid | Anbefaling |
|--------|-----------|-----------------|------------|
| tiny | ~150 MB | 1–2 min | Testing |
| base | ~300 MB | 2–4 min | Korte klipp |
| medium | ~1.4 GB | 10–20 min | Balansert |
| large | ~3 GB | 20–40 min | ✅ Anbefalt |



## Systemkrav

| Krav | Minimum | Anbefalt |
|------|---------|----------|
| Mac | Apple Silicon (M1+) | M2 Pro / M3 |
| macOS | 14 Sonoma | 15 Sequoia |
| RAM | 16 GB | 32 GB |
| Ledig disk | 30 GB | 50 GB |
| Python | 3.10 | 3.12 |

> Intel Mac støttes ikke. NB-Whisper er optimalisert for Apple MPS (Metal Performance Shaders).
