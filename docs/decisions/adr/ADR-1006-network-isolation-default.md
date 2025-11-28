# ADR-1006: Network Isolation as Default Security Posture

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, feature-developer agent

## Context

### Problem Statement

Audio Recording Manager handles sensitive research data that must be protected:
- Interview recordings may contain confidential information
- Accidental cloud sync could expose private data
- Network-enabled apps default to "connected" state
- Users may forget to disable network before handling sensitive files

### Forces at Play

**Technical Requirements:**
- Prevent accidental data exfiltration
- Allow intentional network access when needed (Teams upload)
- Control WiFi, Bluetooth, and AirDrop
- Work without administrative privileges in demo mode

**Constraints:**
- Network control requires administrative privileges on macOS
- Must not break user's system permanently
- Need visual feedback on network state
- Must allow manual override

**Assumptions:**
- Security-first is appropriate for research data handling
- Users can manually enable network when needed
- Brief network disruption is acceptable for security

## Decision

Implement **network isolation as default** - disable all network connectivity on app launch:

### Core Principles

1. **Zero-Trust Default**: Network disabled until explicitly enabled
2. **Reversible Control**: User can override with manual toggle
3. **Visual Feedback**: Clear indication of network state
4. **Graceful Degradation**: Demo mode for development without privileges

### Implementation Details

**Network Control (main.swift):**
```swift
class NetworkManager {
    static let shared = NetworkManager()

    func disableAllConnections() {
        // Disable WiFi
        shell("/usr/sbin/networksetup", "-setairportpower", "en0", "off")

        // Disable Bluetooth
        shell("/opt/homebrew/bin/blueutil", "--power", "0")

        // Disable AirDrop
        shell("osascript", "-e",
            "tell application \"Finder\" to set AirDrop discoverable to false")
    }

    func enableNetwork() {
        shell("/usr/sbin/networksetup", "-setairportpower", "en0", "on")
    }
}
```

**App Launch Behavior:**
```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !DEMO_MODE {
            NetworkManager.shared.disableAllConnections()
        }
    }
}
```

**Demo Mode Flag:**
```swift
// Set to true for development without network control
let DEMO_MODE = false  // Production: false
```

**UI Override Button:**
```swift
Button("Enable Network for Upload") {
    NetworkManager.shared.enableNetwork()
    showNetworkEnabledWarning = true
}
.disabled(isNetworkEnabled)
```

## Consequences

### Positive

- **Data Protection**: Prevents accidental cloud sync/upload
- **Security by Default**: No action needed for secure operation
- **User Awareness**: Manual override makes network use intentional
- **Research Compliance**: Helps meet data handling requirements

### Negative

- **User Disruption**: Network disabled unexpectedly on launch
- **Admin Required**: Full functionality needs administrative privileges
- **External Tool Dependency**: blueutil needed for Bluetooth control
- **macOS Specific**: Implementation tied to macOS APIs

### Neutral

- **Demo Mode**: Development possible without network control
- **Manual Override**: Network can be enabled when needed

## Alternatives Considered

### Alternative 1: Network Enabled by Default

**Description**: Standard app behavior, user disables network manually.

**Rejected because**:
- Users forget to disable network
- Accidental sync/upload risk too high
- Doesn't meet security requirements

### Alternative 2: Prompt on Launch

**Description**: Ask user whether to disable network each launch.

**Rejected because**:
- Extra click on every launch
- Users may click through without reading
- Security should be default, not opt-in

### Alternative 3: Airplane Mode Only

**Description**: Just disable WiFi, not Bluetooth/AirDrop.

**Rejected because**:
- Bluetooth file transfer still possible
- AirDrop could sync files
- Incomplete protection

## Real-World Results

**Observed Behavior:**
- Network disabled within 2 seconds of launch
- Manual override works for Teams uploads
- No reported accidental data exposure

**User Feedback:**
- Initial surprise at network disabling
- Appreciation once purpose understood
- Demo mode useful for development

## Related Decisions

- ADR-1007: NAV Design System Integration (UI for network status)

## References

- `Sources/AudioRecordingManager/main.swift` - NetworkManager class (lines 124-226)
- macOS networksetup documentation
- [blueutil](https://github.com/toy/blueutil) - Bluetooth CLI tool

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
