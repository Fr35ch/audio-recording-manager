# Phase 1 Build Tasks — Teams Upload

**Epic:** File Management & Teams Sync
**Phase:** 1 — Graph API authentication and real upload
**Spec:** [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md)
**Stories:** [USER_STORIES.md](USER_STORIES.md)
**Decision:** [ADR-1014](../../decisions/adr/ADR-1014-file-storage-architecture-pivot.md)

---

## Scope

Phase 1 delivers the actual Microsoft Graph upload, replacing the stub in `TeamsUploadService`.

**Prerequisites (already done):**
- `EntraConfig.swift` — tenant ID, client ID, redirect URI, scopes
- `arm.nav://` URL scheme registered in `Info.plist`
- `TeamsUploadService.upload()` — orchestration and audit logging wired; only `performGraphUpload()` is a stub

---

## Tasks

### 1A — Entra ID sign-in (PKCE)

**File:** `Sources/Clio/Upload/EntraAuthService.swift` (new)

Implement OAuth 2.0 Authorization Code + PKCE sign-in:

1. Add `MSAL` (Microsoft Authentication Library for iOS/macOS) to `Package.swift`:
   ```swift
   .package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc", from: "1.3.0")
   ```
2. Create `EntraAuthService` (`@MainActor`, `ObservableObject`):
   - `signIn()` — opens browser/webview, gets auth code, exchanges for tokens
   - `acquireTokenSilent()` — refresh from MSAL cache; falls back to interactive
   - `signOut()` — clears MSAL cache
   - `@Published var account: MSALAccount?` — nil when signed out
3. Handle `arm.nav://auth/callback` in `AppDelegate` by forwarding to MSAL's `handleMSALResponse(_:sourceApplication:)`.

Config: all values from `EntraConfig` — do not hardcode.

---

### 1B — Wire auth token into Graph upload

**File:** `Sources/Clio/Upload/TeamsUploadService.swift`

Replace the stub `performGraphUpload()`:

```
GET /v1.0/me/joinedTeams  →  find the target team by name/id
GET /v1.0/teams/{id}/channels  →  find the study channel
GET /v1.0/teams/{id}/channels/{id}/filesFolder  →  get the drive item root
PUT /v1.0/drives/{driveId}/items/{parentId}:/{filename}:/content  →  upload (< 4 MB)
```

For files ≥ 4 MB: create upload session + chunked PUT (10 MB chunks). Persist session URL in sidecar for resumability.

All requests: `Authorization: Bearer <token>` from `EntraAuthService.acquireTokenSilent()`.

---

### 1C — Sign-in UX in settings

**File:** `Sources/Clio/Upload/TeamsUploadSection.swift` or a new `TeamsAuthSection.swift`

- Show signed-in user (display name, UPN) when authenticated
- "Logg inn med NAV-konto" button when not authenticated
- "Logg ut" option
- Surface token errors inline (expired, no network, consent revoked)

---

## Entra app registration details

| Field | Value |
|-------|-------|
| Application ID | `db6ed259-83be-4d4e-9329-00c4923d4708` |
| Tenant ID | `62366534-1ec3-4962-8869-9b5535279d0b` |
| Redirect URI | `arm.nav://auth/callback` |
| Display name (Azure portal) | "Audio Recording Manager" → rename to "Clio" |
| Granted scopes | `Files.ReadWrite`, `Sites.ReadWrite.All`, `User.Read`, `ChannelMessage.Read.All` |

> **Note:** Display name rename from "Audio Recording Manager" to "Clio" is cosmetic only — ask NAV IT. Application ID and Tenant ID do not change.
