#if !SANDBOX
    import AppKit
    import CoreGraphics
    import Foundation
    import IOKit

    /// Replaces the built-in keyboard illumination HUD when the keyboard backlight can be
    /// controlled through its IOKit registry property. Unsupported Macs pass the original key on.
    @MainActor
    final class KeyboardIlluminationInterceptor {
        private enum KeyType: Int {
            // NX_KEYTYPE_ILLUMINATION_UP / NX_KEYTYPE_ILLUMINATION_DOWN.
            case illuminationUp = 21
            case illuminationDown = 22
        }

        private static let maximumRawBrightness: Float = 342
        private static let stepCount: Float = 16
        private static let keyDownState = 0x0A
        private static let systemDefinedEventType: UInt32 = 14
        private static let keyboardServiceNames = [
            "AppleHIDKeyboardEventDriverV2",
            "AppleHIDKeyboardEventDriver",
        ]

        private weak var hudController: HUDController?
        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private var isRunning = false
        private let logger = Logger()

        init(hudController: HUDController) {
            self.hudController = hudController
        }

        deinit {}

        /// Start only when an internal keyboard exposing the backlight property is present.
        @discardableResult
        func start() -> Bool {
            guard !isRunning else { return true }
            guard Self.readKeyboardBrightness() != nil else {
                logger.info("No controllable built-in keyboard backlight found; keyboard keys will remain with macOS.")
                return false
            }
            guard AXIsProcessTrusted() else {
                logger.warning("Keyboard illumination interception requires Accessibility permission.")
                return false
            }

            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: 1 << Self.systemDefinedEventType,
                callback: Self.eventTapCallback,
                userInfo: userInfo,
            ) else {
                logger.warning("Could not create keyboard illumination event tap.")
                return false
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                logger.warning("Could not create keyboard illumination event run loop source.")
                return false
            }

            eventTap = tap
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isRunning = true
            logger.info("Keyboard illumination key interception started.")
            return true
        }

        func stop() {
            guard isRunning else { return }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                CFRunLoopSourceInvalidate(runLoopSource)
            }
            eventTap = nil
            runLoopSource = nil
            isRunning = false
        }

        private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let interceptor = Unmanaged<KeyboardIlluminationInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = interceptor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            }

            guard type.rawValue == Self.systemDefinedEventType else {
                return Unmanaged.passRetained(event)
            }
            return interceptor.handleEvent(event)
        }

        /// Perform the adjustment synchronously in the tap callback so failed writes can pass
        /// through to macOS rather than swallowing a key that the app could not handle.
        private nonisolated func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
            guard
                let nsEvent = NSEvent(cgEvent: event),
                nsEvent.type == .systemDefined,
                nsEvent.subtype.rawValue == 8
            else {
                return Unmanaged.passRetained(event)
            }

            let data1 = nsEvent.data1
            let keyCode = (data1 & 0xFFFF_0000) >> 16
            let keyFlags = data1 & 0x0000_FFFF
            let keyState = (keyFlags & 0xFF00) >> 8
            guard keyState == Self.keyDownState, let keyType = KeyType(rawValue: keyCode) else {
                return Unmanaged.passRetained(event)
            }

            guard let brightness = Self.adjustKeyboardBrightness(for: keyType) else {
                return Unmanaged.passRetained(event)
            }

            Task { @MainActor [weak self] in
                self?.hudController?.showKeyboardBrightnessHUD(brightness: brightness)
            }
            return nil
        }

        private nonisolated static func readKeyboardBrightness() -> (service: io_service_t, raw: Float)? {
            for serviceName in keyboardServiceNames {
                guard let matching = IOServiceMatching(serviceName) else { continue }
                let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                guard service != 0 else { continue }
                if let property = IORegistryEntryCreateCFProperty(
                    service,
                    "KeyboardBacklightBrightness" as CFString,
                    kCFAllocatorDefault,
                    0,
                )?.takeRetainedValue() as? NSNumber {
                    let raw = property.floatValue
                    guard raw.isFinite, raw >= 0, raw <= maximumRawBrightness else {
                        IOObjectRelease(service)
                        return nil
                    }
                    return (service, raw)
                }
                IOObjectRelease(service)
            }
            return nil
        }

        private nonisolated static func adjustKeyboardBrightness(for keyType: KeyType) -> Float? {
            guard let (service, currentRawValue) = readKeyboardBrightness() else { return nil }
            defer { IOObjectRelease(service) }

            let step = maximumRawBrightness / stepCount
            let requestedRawValue: Float
            switch keyType {
            case .illuminationUp:
                requestedRawValue = min(maximumRawBrightness, (round(currentRawValue / step) + 1) * step)
            case .illuminationDown:
                requestedRawValue = max(0, (round(currentRawValue / step) - 1) * step)
            }

            let atBoundary = abs(requestedRawValue - currentRawValue) < 0.5
            if !atBoundary {
                let status = IORegistryEntrySetCFProperty(
                    service,
                    "KeyboardBacklightBrightness" as CFString,
                    NSNumber(value: requestedRawValue),
                )
                guard status == KERN_SUCCESS else { return nil }
            }

            guard let readback = IORegistryEntryCreateCFProperty(
                service,
                "KeyboardBacklightBrightness" as CFString,
                kCFAllocatorDefault,
                0,
            )?.takeRetainedValue() as? NSNumber else {
                return nil
            }

            let actualRawValue = readback.floatValue
            guard actualRawValue.isFinite, actualRawValue >= 0, actualRawValue <= maximumRawBrightness else {
                return nil
            }
            if !atBoundary, abs(actualRawValue - currentRawValue) < 0.5 {
                return nil
            }
            return min(1, max(0, actualRawValue / maximumRawBrightness))
        }
    }
#endif
