import Cocoa
import CoreGraphics
import MediaPlayer
import AVFoundation

// macOS System-defined event constants
let NX_SYSDEFINED: UInt32 = 14
let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
let NX_KEYTYPE_PLAY: Int32 = 16

// Left Control virtual keycode is 59 (0x3B)
let CONTROL_KEY_CODE: CGKeyCode = 59

var isRecording = false
var lastToggleTime = Date.distantPast

func sendControlState(down: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(keyboardEventSource: src, virtualKey: CONTROL_KEY_CODE, keyDown: down)
    if down {
        event?.flags = .maskControl
    } else {
        event?.flags = []
    }
    event?.post(tap: .cghidEventTap)
}

func toggleDictation() {
    let now = Date()
    // 300ms debounce to prevent double-firing between CGEventTap and MediaRemote
    if now.timeIntervalSince(lastToggleTime) < 0.3 {
        return
    }
    lastToggleTime = now
    
    isRecording.toggle()
    if isRecording {
        print("[\(Date())] 🎙️ Headset Clicked -> RECORDING STARTED (Control Down)")
        fflush(stdout)
        sendControlState(down: true)
    } else {
        print("[\(Date())] ⏹️ Headset Clicked -> RECORDING STOPPED (Control Up)")
        fflush(stdout)
        sendControlState(down: false)
    }
}

// -------------------------------------------------------------
// Layer 1: Ghost Audio Session (AVAudioEngine)
// Plays a continuous, zero-volume silent PCM loop.
// This registers our daemon with macOS CoreAudio as an active audio producer.
// -------------------------------------------------------------
func setupSilentAudioEngine() -> AVAudioEngine? {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1) else {
        return nil
    }

    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 0.0 // Ensure complete silence

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

// Retain the engine instance globally
let activeAudioEngine = setupSilentAudioEngine()

// -------------------------------------------------------------
// Layer 2: MPRemoteCommandCenter & MPNowPlayingInfoCenter
// Claims active media playback state so nowplayingd routes all
// hardware Play/Pause events exclusively to our daemon.
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
    return .success // Swallows the command cleanly
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
// Layer 3: CoreGraphics Low-Level Event Tap
// Blocks the raw HID keyboard/consumer event stream from reaching WindowServer.
// -------------------------------------------------------------
let callback: CGEventTapCallBack = { proxy, type, event, refcon in
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
                // Completely consume the event
                return nil
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
    callback: callback,
    userInfo: nil
) else {
    fputs("Error: Could not create event tap.\n", stderr)
    fputs("Please enable Accessibility permissions for Terminal / headset_dictation in System Settings -> Privacy & Security -> Accessibility.\n", stderr)
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

print("=====================================================")
print(" 🎙️ Willow Voice 3.5mm Headset Controller")
print(" [Triple-Layer Media Shield Active]")
print("  - Layer 1: AVAudioEngine (Silent audio session lock)")
print("  - Layer 2: MPNowPlayingInfoCenter (nowplayingd priority)")
print("  - Layer 3: CGEventTap (Raw HID media key filter)")
print(" Press Ctrl+C in Terminal to stop.")
print("=====================================================")
fflush(stdout)

// Run the main application loop
NSApplication.shared.run()
