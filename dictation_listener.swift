import Cocoa
import CoreGraphics
import MediaPlayer
import AVFoundation
import IOKit
import IOKit.hid

/// The upstream profile targets Wispr Flow / Willow with Fn+F15. This local
/// installation also supports a `superwhisper` profile using a standard macOS
/// chord (Control+Option+Command+D) that can be entered on keyboards without
/// F15 (such as the Logitech Alto Keys K98M) and registered directly in Superwhisper.
let SUPERWHISPER_PROFILE = ProcessInfo.processInfo.environment["HEADSET_DICTATION_PROFILE"] == "superwhisper"
let TRIGGER_KEY_CODE: CGKeyCode = SUPERWHISPER_PROFILE ? 2 : 113 // D or F15
let FN_KEY_CODE: CGKeyCode = 63

/// Wispr Flow registers push-to-talk as the two-keycode chord [113, 63] (F15 + Fn)
/// and requires a real keycode-63 flagsChanged event — the `.maskSecondaryFn` flag
/// on the F15 event alone is not matched. Both keys must stay down for the whole
/// dictation; releasing Fn early leaves the session orphaned.
///
/// Dictation apps bound to a bare F15, with no modifier, want this off:
///   HEADSET_DICTATION_FN=0
let USE_FN_MODIFIER = !SUPERWHISPER_PROFILE && ProcessInfo.processInfo.environment["HEADSET_DICTATION_FN"] != "0"
let TRIGGER_FLAGS: CGEventFlags = SUPERWHISPER_PROFILE
    ? [.maskControl, .maskAlternate, .maskCommand]
    : (USE_FN_MODIFIER ? .maskSecondaryFn : [])
let TRIGGER_NAME = SUPERWHISPER_PROFILE ? "Control+Option+Command+D" : (USE_FN_MODIFIER ? "Fn+F15" : "F15")

/// Release the chord unconditionally after this long, so a missed second click
/// cannot leave Fn and F15 virtually held down forever.
let MAX_RECORDING_SECONDS: TimeInterval = 300

/// Repeat presses closer together than this are switch bounce (~170 ms on the
/// Sony IER-EX15C), not a second click.
let DEBOUNCE_SECONDS: TimeInterval = 0.6

/// Devices that are not seized (USB-C headsets such as the Sony IER-EX15C) deliver
/// one click through multiple macOS media pipelines (e.g., CGEventTap then
/// MPRemoteCommandCenter 0.6–1.3 s later, or CGEventTap and IOHIDManager). Any
/// cross-source delivery or Now Playing command this soon after an initial press
/// is dropped instead of flipping the recording state back.
let REMOTE_COMMAND_ECHO_SECONDS: TimeInterval = 2.0

enum ClickSource: String {
    case hid = "IOHIDManager"
    case eventTap = "CGEventTap"
    case remoteToggle = "MPRemoteCommandCenter.toggle"
    case remotePlay = "MPRemoteCommandCenter.play"
    case remotePause = "MPRemoteCommandCenter.pause"

    var isRemoteCommand: Bool {
        self == .remoteToggle || self == .remotePlay || self == .remotePause
    }
}

/// Decides whether a reported press is a new click. Kept free of side effects so
/// a recorded log can be replayed against it.
struct ClickFilter {
    private var lastAcceptedTime = Date.distantPast
    private var lastAcceptedSource: ClickSource?
    private var lastDirectPressTime = Date.distantPast

    enum Verdict: Equatable {
        case accept
        case debounced
        case remoteEcho
        case crossSourceDuplicate
    }

    func elapsedSinceLastAccepted(at now: Date) -> TimeInterval {
        now.timeIntervalSince(lastAcceptedTime)
    }

    mutating func evaluate(_ source: ClickSource, at now: Date) -> Verdict {
        if source.isRemoteCommand {
            if now.timeIntervalSince(lastDirectPressTime) < REMOTE_COMMAND_ECHO_SECONDS {
                return .remoteEcho
            }
        } else {
            lastDirectPressTime = now
        }
        if let lastSource = lastAcceptedSource,
           lastSource != source,
           now.timeIntervalSince(lastAcceptedTime) < REMOTE_COMMAND_ECHO_SECONDS {
            return .crossSourceDuplicate
        }
        if now.timeIntervalSince(lastAcceptedTime) < DEBOUNCE_SECONDS {
            return .debounced
        }
        lastAcceptedTime = now
        lastAcceptedSource = source
        return .accept
    }
}

@MainActor
class DictationController {
    static let shared = DictationController()

    private var isRecording = false
    private var clickFilter = ClickFilter()
    private var watchdog: Task<Void, Never>?

    private init() {}

    /// Drop the chord if it is still held. Safe to call when not recording.
    func releaseIfHeld() {
        guard isRecording else { return }
        isRecording = false
        watchdog?.cancel()
        watchdog = nil
        sendTriggerState(down: false)
    }

    func toggleDictation(source: ClickSource) {
        let now = Date()
        let elapsed = clickFilter.elapsedSinceLastAccepted(at: now)
        print("[\(now)] Triggered by: \(source.rawValue) (Elapsed: \(String(format: "%.3f", elapsed))s)")
        fflush(stdout)

        switch clickFilter.evaluate(source, at: now) {
        case .accept:
            break
        case .debounced:
            print("  -> Dropped (Debounced)")
            fflush(stdout)
            return
        case .remoteEcho:
            print("  -> Dropped (Now Playing echo of a tap/HID press)")
            fflush(stdout)
            return
        case .crossSourceDuplicate:
            print("  -> Dropped (Cross-source duplicate)")
            fflush(stdout)
            return
        }

        isRecording.toggle()
        let chord = TRIGGER_NAME
        if isRecording {
            print("[\(now)] 🎙️ Headset Clicked -> RECORDING STARTED (\(chord) Down)")
            fflush(stdout)
            sendTriggerState(down: true)
            startWatchdog()
        } else {
            print("[\(now)] ⏹️ Headset Clicked -> RECORDING STOPPED (\(chord) Up)")
            fflush(stdout)
            watchdog?.cancel()
            watchdog = nil
            sendTriggerState(down: false)
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MAX_RECORDING_SECONDS * 1_000_000_000))
            guard !Task.isCancelled, self.isRecording else { return }
            print("[\(Date())] ⚠️ Watchdog: releasing chord after \(Int(MAX_RECORDING_SECONDS))s")
            fflush(stdout)
            self.isRecording = false
            self.sendTriggerState(down: false)
        }
    }

    /// Posts the chord in the order Wispr Flow matches it: Fn leads on press and
    /// trails on release, so both keys are down for the entire dictation.
    private func sendTriggerState(down: Bool) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let flags = TRIGGER_FLAGS

        if down && USE_FN_MODIFIER {
            postFlagsChanged(src, keyCode: FN_KEY_CODE, flags: .maskSecondaryFn)
            usleep(30_000)
        }

        if let event = CGEvent(keyboardEventSource: src, virtualKey: TRIGGER_KEY_CODE, keyDown: down) {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }

        if !down && USE_FN_MODIFIER {
            usleep(30_000)
            postFlagsChanged(src, keyCode: FN_KEY_CODE, flags: [])
        }
    }

    private func postFlagsChanged(_ src: CGEventSource, keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(source: src) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = flags
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
            Task { @MainActor in DictationController.shared.toggleDictation(source: .remoteToggle) }
            return .success
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in DictationController.shared.toggleDictation(source: .remotePlay) }
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in DictationController.shared.toggleDictation(source: .remotePause) }
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
                Task { @MainActor in DictationController.shared.toggleDictation(source: .hid) }
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
                Task { @MainActor in DictationController.shared.toggleDictation(source: .eventTap) }
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
        ) else {
            // Almost always Accessibility. The grant is tied to the binary's cdhash
            // under ad-hoc signing, so any rebuild invalidates it and lands here.
            FileHandle.standardError.write(Data("""
                FATAL: could not create the event tap — Accessibility is not granted.
                AXIsProcessTrusted() = \(AXIsProcessTrusted())

                Open System Settings -> Privacy & Security -> Accessibility, remove any
                existing "Headset Dictation" entry with the - button, then add
                \(Bundle.main.bundlePath)
                and make sure it is toggled on. Re-run `make install` afterwards.

                """.utf8))
            exit(1)
        }
        globalEventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}

/// A daemon killed mid-dictation would otherwise leave Fn+F15 virtually held.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { DictationController.shared.releaseIfHeld() }
        exit(0)
    }
    source.resume()
    signalSources.append(source)
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
