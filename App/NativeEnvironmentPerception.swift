import Foundation
import CoreAudio
import IOKit.ps

struct CompanionPowerSnapshot: Equatable {
    var subject: String
    var constrained: Bool
    static func classify(thermal: Int, lowPower: Bool, percent: Int?, charging: Bool, acPower: Bool) -> Self {
        if thermal >= 2 { return .init(subject: "thermal_pressure", constrained: true) }
        if lowPower { return .init(subject: "low_power_mode", constrained: true) }
        if let percent, percent <= 15, !acPower { return .init(subject: "battery_low", constrained: true) }
        return .init(subject: charging ? "charging" : acPower ? "ac_power" : percent == nil ? "power_unknown" : "battery_power", constrained: false)
    }
    static func current() -> Self {
        var percent: Int?, charging = false, ac = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let values = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for value in values {
                guard let data = IOPSGetPowerSourceDescription(info, value)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0, let current = data[kIOPSCurrentCapacityKey] as? Int { percent = min(100, max(0, Int(Double(current) / Double(maximum) * 100))) }
                charging = (data[kIOPSIsChargingKey] as? Bool) ?? false
                ac = (data[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                break
            }
        }
        return classify(thermal: ProcessInfo.processInfo.thermalState.rawValue, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, percent: percent, charging: charging, acPower: ac)
    }
}

@MainActor final class NativeAudioPerception {
    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []
    private var device: AudioObjectID = 0
    private var epoch: Int?
    private var generation = 0
    private let sink: (CompanionMacSignal) -> Void
    init(sink: @escaping (CompanionMacSignal) -> Void) { self.sink = sink }
    private func value(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, size == MemoryLayout<UInt32>.size else { return nil }
        return result
    }
    func configure(epoch: Int?, sleeping: Bool) {
        let desired = sleeping ? nil : epoch
        guard self.epoch != desired else { return }
        stop(); self.epoch = desired
        guard desired != nil else { return }
        add(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        add(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
        refresh(initial: true)
    }
    private func add(_ object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let expected = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in guard let self, self.generation == expected else { return }; if selector == kAudioHardwarePropertyDevices { self.device = 0 }; self.refresh(initial: false) }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners.append(.init(object: object, address: address, block: block)) }
    }
    private func refresh(initial: Bool) {
        guard let epoch else { return }
        guard let output = value(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice), output != kAudioObjectUnknown else {
            sink(.init(source: "macos.audio", type: "environment.audio_state", subject: "audio_route_unknown", initial: initial, health: "temporarily_unavailable", epoch: epoch)); return
        }
        if device != output {
            for entry in listeners where entry.object != kAudioObjectSystemObject {
                var address = entry.address; _ = AudioObjectRemovePropertyListenerBlock(entry.object, &address, .main, entry.block)
            }
            listeners.removeAll { $0.object != kAudioObjectSystemObject }
            device = output
            add(output, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        let transport = value(output, selector: kAudioDevicePropertyTransportType)
        let subject = transport == kAudioDeviceTransportTypeBuiltIn ? "audio_route_builtin" : transport == nil ? "audio_route_unknown" : "audio_route_external"
        // Device IDs/names, stream contents and audio samples are never returned.
        sink(.init(source: "macos.audio", type: "environment.audio_state", subject: subject, initial: initial, epoch: epoch,
            audioActive: value(output, selector: kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 }))
    }
    func stop() {
        generation += 1; epoch = nil; device = 0
        for entry in listeners { var address = entry.address; _ = AudioObjectRemovePropertyListenerBlock(entry.object, &address, .main, entry.block) }
        listeners = []
    }
}
