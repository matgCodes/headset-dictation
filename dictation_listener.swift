import Cocoa
import CoreGraphics
import MediaPlayer
import AVFoundation
import IOKit
import IOKit.hid

// F15 virtual keycode is 113 (0x71) - clean, unassigned extended function key
let TRIGGER_KEY_CODE: CGKeyCode = 113

var isRecording = false
var lastToggleTime = Date.distantPast

func sendTriggerState(down: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(keyboardEventSource: src, virtualKey: TRIGGER_KEY_CODE, keyDown: down)
    event?.flags = [] // F15 does not require modifier masks
    event?.post(tap: .cghidEventTap)
}

func toggleDictation() {
    let now = Date()
    // 300ms software debounce
    if now.timeIntervalSince(lastToggleTime) < 0.3 {
        return
    }
    lastToggleTime = now
    
    isRecording.toggle()
    if isRecording {
        print("[\(Date())] 🎙️ Headset Clicked -> RECORDING STARTED (F15 Down)")
        fflush(stdout)
        sendTriggerState(down: true)
    } else {
        print("[\(Date())] ⏹️ Headset Clicked -> RECORDING STOPPED (F15 Up)")
        fflush(stdout)
        sendTriggerState(down: false)
    }
}

// -------------------------------------------------------------
// Layer 1: Ghost Audio Session (AVAudioEngine)
// Plays a continuous, zero-volume silent PCM loop so CoreAudio
// registers active audio output from our process.
// -------------------------------------------------------------
func setupSilentAudioEngine() -> AVAudioEngine? {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1) else {
        return nil
    }

    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 0.0

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
        return nil
    }
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
        print("⚠️ Warning: Could not start silent audio engine: \(error)")
        return nil
    }
}

let activeAudioEngine = setupSilentAudioEngine()

// -------------------------------------------------------------
// Layer 2: MPNowPlayingInfoCenter & MPRemoteCommandCenter
// Claims active media playback state so nowplayingd routes all
// hardware Play/Pause events to our daemon.
// -------------------------------------------------------------
let nowPlayingCenter = MPNowPlayingInfoCenter.default()
nowPlayingCenter.nowPlayingInfo = [
    MPMediaItemPropertyTitle: "Headset Dictation Shield",
    MPMediaItemPropertyArtist: "System Daemon"
]
nowPlayingCenter.playbackState = .playing

let commandCenter = MPRemoteCommandCenter.shared()

commandCenter.togglePlayPauseCommand.isEnabled = true
commandCenter.togglePlayPauseCommand.addTarget { _ in
    toggleDictation()
    return .success
}

commandCenter.playCommand.isEnabled = true
commandCenter.playCommand.addTarget { _ in
    toggleDictation()
    return .success
}

commandCenter.pauseCommand.isEnabled = true
commandCenter.pauseCommand.addTarget { _ in
    toggleDictation()
    return .success
}

// -------------------------------------------------------------
// Layer 3: IOHIDManager Hardware Stream Listener (Shared Mode)
// -------------------------------------------------------------
let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matchingDict: [String: Any] = [
    kIOHIDTransportKey as String: "Audio",
    kIOHIDProductKey as String: "Headset"
]
IOHIDManagerSetDeviceMatching(hidManager, matchingDict as CFDictionary)

let hidCallback: IOHIDValueCallback = { context, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    if usagePage == 12 && intValue == 1 {
        toggleDictation()
    }
}

IOHIDManagerRegisterInputValueCallback(hidManager, hidCallback, nil)
IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let hidOpenResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

// -------------------------------------------------------------
// Layer 4: Low-Level Event Tap (CGEventTap)
// Drops NX_KEYTYPE_PLAY events before they reach WindowServer.
// -------------------------------------------------------------
let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    if type.rawValue == NX_SYSDEFINED {
        if let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS {
            let data1 = nsEvent.data1
            let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
            let keyFlags = (data1 & 0x0000FF00) >> 8
            let isKeyDown = (keyFlags == 0x0A)

            if keyCode == NX_KEYTYPE_PLAY {
                if isKeyDown {
                    toggleDictation()
                }
                return nil // Completely drop the event
            }
        }
    }
    return Unmanaged.passUnretained(event)
}

guard let eventTap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED),
    callback: eventTapCallback,
    userInfo: nil
) else {
    fputs("Error: Could not create event tap. Ensure Accessibility permissions are granted.\n", stderr)
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

print("=====================================================")
print(" 🎙️ Willow Voice 3.5mm Headset Controller")
print(" [Multi-Layer Active Shield Online]")
print("  - IOHID Status:     \(hidOpenResult == kIOReturnSuccess ? "Connected" : "Idle")")
print("  - CGEventTap:       Active (Dropping NX_KEYTYPE_PLAY)")
print("  - MPRemoteCommand:  Active (Swallowing NowPlaying)")
print("  - Virtual Key:      F15 (keyCode 113)")
print("=====================================================")
fflush(stdout)

// Run the main application loop
NSApplication.shared.run()
