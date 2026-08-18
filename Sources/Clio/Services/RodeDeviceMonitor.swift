import CoreAudio
import Foundation

// MARK: - RØDE Device Monitor

/// Watches CoreAudio for a connected RØDE **dual-channel wireless receiver**
/// (Wireless GO / Wireless Micro / Wireless ME) and publishes its connection
/// state, name, device ID, and stereo capability.
///
/// Hardware diarization relies on each lavalier transmitter occupying its own
/// channel, so this monitor deliberately *ignores* single-capsule RØDE mics
/// such as the NT-USB — those are mono and must fall through to the normal
/// (FluidAudio) diarization path. A device only qualifies when its name matches
/// a known wireless-receiver model AND it exposes ≥ 2 input channels.
///
/// Hot-plug events are delivered via `AudioObjectAddPropertyListenerBlock` on the system object.
/// All @Published mutations run on the main queue.
final class RodeDeviceMonitor: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var deviceName: String? = nil
    @Published private(set) var deviceID: AudioDeviceID? = nil
    @Published private(set) var isStereoCapable: Bool = false

    // MARK: - Private

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    // RØDE wireless-receiver model substrings (case-insensitive). Single-capsule
    // mics (NT-USB, SC-series, Podcaster, etc.) are intentionally excluded —
    // they are mono and cannot drive channel-split diarization.
    private let rodeKeywords = [
        "wireless go", "wireless micro", "wireless me",
        "rode wireless", "røde wireless",
    ]

    // MARK: - Init / deinit

    init() {
        scan()
        registerHotplugListener()
    }

    deinit {
        unregisterHotplugListener()
    }

    // MARK: - Public

    /// Re-scans all CoreAudio input devices immediately.
    func refresh() {
        scan()
    }

    // MARK: - Private helpers

    private func scan() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr else {
            publishAbsent()
            return
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else {
            publishAbsent()
            return
        }

        for id in ids {
            guard let name = deviceName(for: id), isRodeDevice(name: name) else { continue }
            guard hasInputStream(id) else { continue }
            // Hardware diarization requires a true 2-channel input. A RØDE
            // device that only exposes a mono stream (or is mid-handshake)
            // does not qualify — fall through so the built-in/ML path is used.
            guard isStereo(id) else { continue }
            publishFound(id: id, name: name, stereo: true)
            return
        }

        publishAbsent()
    }

    private func publishFound(id: AudioDeviceID, name: String, stereo: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.deviceID = id
            self.deviceName = name
            self.isStereoCapable = stereo
        }
    }

    private func publishAbsent() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.deviceID = nil
            self.deviceName = nil
            self.isStereoCapable = false
        }
    }

    // MARK: - Device queries

    private func isRodeDevice(name: String) -> Bool {
        let lower = name.lowercased()
        return rodeKeywords.contains { lower.contains($0.lowercased()) }
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameRef: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &nameRef) == noErr else {
            return nil
        }
        return nameRef as String
    }

    private func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func isStereo(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        // AudioBufferList has variable size — allocate raw bytes, then read
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, bufferListPtr) == noErr else {
            return false
        }

        let bufferList = bufferListPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)

        // Sum all channel counts across input streams
        var totalChannels = 0
        withUnsafePointer(to: &bufferList.pointee.mBuffers) { buffersPtr in
            for i in 0..<bufferCount {
                let buf = buffersPtr.advanced(by: i)
                totalChannels += Int(buf.pointee.mNumberChannels)
            }
        }

        return totalChannels >= 2
    }

    // MARK: - Hot-plug listener

    private func registerHotplugListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scan()
        }
        listenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.global(qos: .utility),
            block
        )
        if status != noErr {
            print("⚠️ RodeDeviceMonitor: failed to register hot-plug listener (\(status))")
        }
    }

    private func unregisterHotplugListener() {
        guard let block = listenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.global(qos: .utility),
            block
        )
        listenerBlock = nil
    }
}
