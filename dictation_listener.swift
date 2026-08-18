import Cocoa
import CoreGraphics
import MediaPlayer
import AVFoundation
import IOKit
import IOKit.hid

let TRIGGER_KEY_CODE: CGKeyCode = 113

@MainActor
class DictationController {
    static let shared = DictationController()
    
    private var isRecording = false
    private var lastToggleTime = Date.distantPast
    
    private init() {}
    
    func toggleDictation(source: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastToggleTime)
        print("[\(now)] Triggered by: \(source) (Elapsed: \(String(format: "%.3f", elapsed))s)")
        fflush(stdout)
        
        if elapsed < 0.6 {
            print("  -> Dropped (Debounced)")
            fflush(stdout)
            return
        }
        lastToggleTime = now
        
        isRecording.toggle()
        if isRecording {
            print("[\(now)] 🎙️ Headset Clicked -> RECORDING STARTED (F15 Down)")
            fflush(stdout)
            sendTriggerState(down: true)
        } else {
            print("[\(now)] ⏹️ Headset Clicked -> RECORDING STOPPED (F15 Up)")
            fflush(stdout)
            sendTriggerState(down: false)
        }
    }
    
    private func sendTriggerState(down: Bool) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: src, virtualKey: TRIGGER_KEY_CODE, keyDown: down) else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}

class MediaShieldAdapter {
    private var activeAudioEngine: AVAudioEngine?
    func start() {
        activeAudioEngine = setupSilentAudioEngine()
    }
    private func setupSilentAudioEngine() -> AVAudioEngine? {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1) else { return nil }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return nil }
        buffer.frameLength = 1024
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(repeating: 0.0, count: 1024)
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            return engine
        } catch {
            return nil
        }
    }
}

class RemoteCommandAdapter {
    func start() {
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: "Headset Dictation Shield", MPMediaItemPropertyArtist: "System Daemon"]
        nowPlayingCenter.playbackState = .playing

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in DictationController.shared.toggleDictation(source: "MPRemoteCommandCenter.toggle") }
            return .success
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in DictationController.shared.toggleDictation(source: "MPRemoteCommandCenter.play") }
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in DictationController.shared.toggleDictation(source: "MPRemoteCommandCenter.pause") }
            return .success
        }
    }
}

class HIDListenerAdapter {
    private var hidManager: IOHIDManager?
    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager
        let matchingDict: [String: Any] = [kIOHIDTransportKey as String: "Audio", kIOHIDProductKey as String: "Headset"]
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)

        let hidCallback: IOHIDValueCallback = { context, result, sender, value in
            let element = IOHIDValueGetElement(value)
            if IOHIDElementGetUsagePage(element) == 12 && IOHIDValueGetIntegerValue(value) == 1 {
                Task { @MainActor in DictationController.shared.toggleDictation(source: "IOHIDManager") }
            }
        }
        IOHIDManagerRegisterInputValueCallback(manager, hidCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }
}

var globalEventTap: CFMachPort?

let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == NX_SYSDEFINED, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS {
        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = (data1 & 0x0000FF00) >> 8
        if keyCode == NX_KEYTYPE_PLAY {
            if keyFlags == 0x0A {
                Task { @MainActor in DictationController.shared.toggleDictation(source: "CGEventTap") }
            }
            return nil
        }
    }
    return Unmanaged.passUnretained(event)
}

class EventTapAdapter {
    func start() {
        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED), callback: eventTapCallback, userInfo: nil
        ) else { exit(1) }
        globalEventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}

let mediaShield = MediaShieldAdapter()
mediaShield.start()
let remoteCommandAdapter = RemoteCommandAdapter()
remoteCommandAdapter.start()
let hidAdapter = HIDListenerAdapter()
hidAdapter.start()
let eventTapAdapter = EventTapAdapter()
eventTapAdapter.start()
NSApplication.shared.run()
