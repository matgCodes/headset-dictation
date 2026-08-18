import Cocoa
import CoreGraphics
import IOKit
import IOKit.hid

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
    // 300ms software debounce to prevent hardware bounce
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
// IOKit Exclusive Hardware Seize for 3.5mm Wired Headset
// Intercepts the dedicated "Audio" transport stream at the driver level,
// preventing Chrome, nowplayingd, and all media players from seeing it.
// -------------------------------------------------------------

let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// Match only the wired 3.5mm headset audio remote control
let matchingDict: [String: Any] = [
    kIOHIDTransportKey as String: "Audio",
    kIOHIDProductKey as String: "Headset"
]

IOHIDManagerSetDeviceMatching(hidManager, matchingDict as CFDictionary)

// Low-level hardware input callback
let hidCallback: IOHIDValueCallback = { context, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    // UsagePage 12 (Consumer Controls): intValue 1 = button pressed down
    if usagePage == 12 && intValue == 1 {
        toggleDictation()
    }
}

IOHIDManagerRegisterInputValueCallback(hidManager, hidCallback, nil)
IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

// Open the headset device in EXCLUSIVE SEIZE mode
let openStatus = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
if openStatus != kIOReturnSuccess {
    print("⚠️ Notice: IOHIDManagerOpen seize returned status code: \(openStatus)")
    print("   (Will automatically seize when headset is connected)")
}

print("=====================================================")
print(" 🎙️ Willow Voice 3.5mm Headset Controller")
print(" [IOKit Hardware Seize Mode Active]")
print("  - Isolated Stream: Transport = Audio (Device: Headset)")
print("  - Media Immunity:  100% (Chrome / Spotify / Music bypassed)")
print("  - Action:          Left Control (Toggle Dictation)")
print(" Press Ctrl+C to stop.")
print("=====================================================")
fflush(stdout)

// Run the main application loop
NSApplication.shared.run()
