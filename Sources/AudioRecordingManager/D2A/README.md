# D2A Bridge Module

This module imports Olympus D2A audio files (encrypted dictations from
DS-9500 and similar devices) into ARM, by routing decryption through a
Windows VM running the [d2aDecrypter](https://github.com/Fr35ch/d2aDecrypter)
service.

The full architecture is documented in
[`D2A_BRIDGE_INTEGRATION_PLAN.md`](../../../D2A_BRIDGE_INTEGRATION_PLAN.md).

## Files

| File | Role |
|------|------|
| `Models/D2AFile.swift` | Value type for a `.d2a` discovered on an SD card |
| `Models/DecryptionTask.swift` | Per-import progress record (queued → completed) |
| `Models/VMServiceConfig.swift` | Endpoint + shared-folder paths, loaded from disk |
| `Services/VMServiceClient.swift` | Async REST client for the VM service (`/api/health`, `/api/decrypt`, `/api/status`) |
| `Services/SDCardWatcher.swift` | Wraps `SDCardManager.shared`; publishes `[D2AFile]` for the current volume |
| `Services/D2AConverter.swift` | Local-side helpers: validation, sanitised paths, file copies, cleanup |
| `Services/D2ABridgeService.swift` | Coordinator — owns the import pipeline and `[DecryptionTask]` |
| `Views/PasswordPromptView.swift` | Modal sheet asking for the file password |
| `Views/D2AProgressView.swift` | In-flight task strip shown above the file list |
| `Views/D2AImportView.swift` | Top-level tab UI |

## Integration steps (still TODO)

These are intentionally **not** wired up automatically — they touch
shared code paths that should be reviewed before merging.

### 1. Add files to the Xcode target

`Package.swift` globs `Sources/AudioRecordingManager/`, so SwiftPM picks
up the new files automatically. The Xcode project (`.pbxproj`), however,
does not. Either:

- Drag the `D2A/` folder into the AudioRecordingManager group in Xcode
  with "Add to targets: AudioRecordingManager" checked, or
- Build via `swift build` to verify compilation while skipping the
  Xcode project.

### 2. Add a `d2aImport` tab

In [`TranscriptsView.swift`](../TranscriptsView.swift), add a case:

```swift
enum AppTab {
    case record
    case recordings
    case transcripts
    case d2aImport   // ← new
}
```

Then add a navigation row in `NavPanel` (in `main.swift`) and a content
branch in `MainView` that renders `D2AImportView()` when the tab is
selected.

### 3. Create a config file

The bridge refuses to talk to the VM until a config file exists at:

```
~/Library/Application Support/AudioRecordingManager/d2a-config.json
```

Example contents:

```json
{
  "serviceURL": "http://192.168.65.2:8080",
  "sharedFolderPath": "/Volumes/VMwareShared/SharedFolder",
  "connectionTimeout": 30,
  "maxRetries": 3
}
```

Replace `192.168.65.2` with the IP of the VMware Fusion guest. The IP
is stable per-VM; check it with `ipconfig` inside the Windows VM.

### 4. VMware Fusion + Windows VM setup

1. Install VMware Fusion and a Windows 11 VM.
2. Install the d2aDecrypter service per the
   [project README](https://github.com/Fr35ch/d2aDecrypter).
3. Enable Shared Folders in VMware Fusion → name the shared folder
   `SharedFolder` and point it at a folder on the Mac.
4. In the Windows VM, ensure the shared folder is mapped (typically as
   `Z:\`).
5. Configure the d2aDecrypter service to read from `Z:\input` and write
   to `Z:\output`.
6. Open port 8080 in the Windows firewall, or run the VM with
   bridged networking and a known IP.

## Security and compliance notes

This module ships D2A audio bytes from the Mac into a VM over the
loopback-equivalent VMware shared folder, then receives the decrypted
audio back. A few things worth flagging for the project owner before
the bridge is enabled in production:

- **HTTP, not HTTPS.** The REST channel between Mac and VM is plaintext.
  This is acceptable on a single host where the VM only listens on a
  host-only network, but the config file should be reviewed to confirm
  the service URL is not reachable from the LAN.
- **Password in request body.** `POST /api/decrypt` carries the user's
  device password as a JSON field. It is logged by neither this client
  nor (per the d2aDecrypter README) the service, but it is in memory
  on both sides while a request is in flight.
- **Decrypted audio temporarily lives in the VM shared folder.** The
  bridge cleans up after import (best-effort), but a crash during
  import can leave a decrypted `.m4a` in `SharedFolder/output/`. The
  shared folder must be excluded from any sync/backup mechanism on
  the Mac for the same reason `~/Library/Application Support/AudioRecordingManager/`
  is — see ADR-1014.
- **Olympus SDK is closed source.** The decryption itself happens
  inside the SDK on Windows; we treat it as a black box and only
  observe its outputs.

This is not a substitute for a privacy review by the NAV PVK process —
flag for the product owner before exposing the D2A tab to researchers.

## Relationship to the trashed `ds2_decoder/` scaffold

A previous local C++ scaffold at `Sources/ds2_decoder/` (now in
`~/.arm-trash/`) was an earlier attempt at the same problem using a
hypothetical OM System Audio SDK directly on macOS. That approach is
superseded by this bridge — Olympus does not ship a macOS SDK, so
the Windows VM is the only path that works without reverse-engineering
the file format.
