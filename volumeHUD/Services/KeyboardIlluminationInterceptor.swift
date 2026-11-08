#if !SANDBOX
    import AppKit
    import CoreGraphics
    import Foundation
    import IOKit

    /// Intercepts keyboard illumination media keys, adjusts the built-in keyboard backlight,
    /// and presents the app's replacement HUD. If the private IOKit property is unavailable or
    /// cannot be changed, the key is passed through to macOS unchanged.
    @MainActor
    final class KeyboardIlluminationInterceptor {
        private enum KeyType: Int {
            case illuminationUp = 21
            case illuminationDown = 22
        }

        private static let maximumRawBrightness: Float = 342
        private static let keyDownState = 0x0A
        private static let systemDefinedEventType: UInt32 = 14

        private weak var hudController: KeyboardBrightnessHUDController?
        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private var isRunning = false
        private let logger = Logger()

        init(hudController: KeyboardBrightnessHUDController) {
            self.hudController = hudController
        }

        deinit {}

        @discardableResult
        func start() -> Bool {
            guard !isRunning else { return true }
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
                self?.hudController?.show(brightness: brightness)
            }
            return nil
        }

        /// Reads and updates the private keyboard-backlight registry property. Returning nil keeps
        /// the original key event intact, allowing macOS to handle unsupported hardware normally.
        private nonisolated static func adjustKeyboardBrightness(for keyType: KeyType) -> Float? {
            let serviceNames = [
                "AppleHIDKeyboardEventDriverV2",
                "AppleHIDKeyboardEventDriver",
                "AppleKeyboard",
            ]

            var keyboardService: io_service_t = 0
            for serviceName in serviceNames {
                if let matching = IOServiceMatching(serviceName) {
                    keyboardService = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                }
                if keyboardService != 0 { break }
            }
            guard keyboardService != 0 else { return nil }
            defer { IOObjectRelease(keyboardService) }

            let propertyKey = "KeyboardBacklightBrightness" as CFString
            guard let property = IORegistryEntryCreateCFProperty(
                keyboardService,
                propertyKey,
                kCFAllocatorDefault,
                0,
            )?.takeRetainedValue() as? NSNumber else {
                return nil
            }

            let currentRawValue = property.floatValue
            guard currentRawValue.isFinite, currentRawValue >= 0, currentRawValue <= maximumRawBrightness else {
                return nil
            }

            let delta = maximumRawBrightness / 16
            let requestedRawValue: Float
            switch keyType {
            case .illuminationUp:
                requestedRawValue = min(maximumRawBrightness, currentRawValue + delta)
            case .illuminationDown:
                requestedRawValue = max(0, currentRawValue - delta)
            }

            let newValue = NSNumber(value: requestedRawValue)
            guard IORegistryEntrySetCFProperty(keyboardService, propertyKey, newValue) == KERN_SUCCESS,
                  let readback = IORegistryEntryCreateCFProperty(
                      keyboardService,
                      propertyKey,
                      kCFAllocatorDefault,
                      0,
                  )?.takeRetainedValue() as? NSNumber else {
                return nil
            }

            let actualRawValue = readback.floatValue
            guard actualRawValue.isFinite, actualRawValue >= 0, actualRawValue <= maximumRawBrightness else {
                return nil
            }
            let didChange = abs(actualRawValue - currentRawValue) > 0.5
            let isAtRequestedBoundary = requestedRawValue == currentRawValue
            guard didChange || isAtRequestedBoundary else { return nil }

            return min(1, max(0, actualRawValue / maximumRawBrightness))
        }
    }
#endif
