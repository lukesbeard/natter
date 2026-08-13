import CoreAudio
import Foundation

/// While a dictation session is active, silence the speakers and pause any
/// now-playing media, then restore both when the session ends. Muting the
/// output device is reliable via CoreAudio; pausing media is best-effort
/// through the private MediaRemote framework and is skipped silently if that
/// framework is unavailable or restricted.
@MainActor
final class MediaInterruptionController {
    private var isActive = false

    // Saved output state for restore.
    private var mutedDevice: AudioDeviceID = 0
    private var savedMute: UInt32?
    private var savedVolume: Float32?

    // Whether we actually issued a pause we are responsible for resuming.
    private var didPauseMedia = false

    func begin() {
        guard !isActive else { return }
        isActive = true
        muteDefaultOutput()
        pauseMediaIfPlaying()
    }

    func end() {
        guard isActive else { return }
        isActive = false
        restoreDefaultOutput()
        if didPauseMedia {
            didPauseMedia = false
            MediaRemoteControl.sendCommand(.play)
        }
    }

    // MARK: - Output muting (CoreAudio)

    private func muteDefaultOutput() {
        savedMute = nil
        savedVolume = nil
        guard let device = Self.defaultOutputDevice() else { return }
        mutedDevice = device

        // Prefer the device master mute when it is settable.
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if Self.isSettable(device, &muteAddress) {
            var current: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &current) == noErr {
                savedMute = current
                var on: UInt32 = 1
                AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &on)
                return
            }
        }

        // Fall back to dropping the master output volume to zero.
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if Self.isSettable(device, &volumeAddress) {
            var current: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &current) == noErr {
                savedVolume = current
                var zero: Float32 = 0
                AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &zero)
            }
        }
    }

    private func restoreDefaultOutput() {
        guard mutedDevice != 0 else { return }
        defer { mutedDevice = 0 }

        if var saved = savedMute {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(mutedDevice, &address, 0, nil, size, &saved)
            savedMute = nil
        }
        if var saved = savedVolume {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectSetPropertyData(mutedDevice, &address, 0, nil, size, &saved)
            savedVolume = nil
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device
        )
        return (status == noErr && device != 0) ? device : nil
    }

    private static func isSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    // MARK: - Media pause (MediaRemote, best-effort)

    private func pauseMediaIfPlaying() {
        MediaRemoteControl.getIsPlaying { [weak self] isPlaying in
            Task { @MainActor in
                guard let self, self.isActive, isPlaying else { return }
                MediaRemoteControl.sendCommand(.pause)
                self.didPauseMedia = true
            }
        }
    }
}

/// Thin dlopen bridge to the private MediaRemote framework. All entry points
/// no-op if the framework or a symbol is missing.
private enum MediaRemoteControl {
    enum Command: Int {
        case play = 0
        case pause = 1
    }

    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool
    private typealias IsPlayingFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    // Loaded once at first use and never mutated; the C pointer types are not
    // Sendable, so opt out of the concurrency checks explicitly.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_LAZY
    )

    nonisolated(unsafe) private static let sendCommandFn: SendCommandFn? = symbol("MRMediaRemoteSendCommand")
    nonisolated(unsafe) private static let isPlayingFn: IsPlayingFn? = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static func sendCommand(_ command: Command) {
        _ = sendCommandFn?(command.rawValue, nil)
    }

    static func getIsPlaying(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let isPlayingFn else { completion(false); return }
        isPlayingFn(DispatchQueue.global(qos: .userInitiated)) { playing in
            completion(playing)
        }
    }
}
