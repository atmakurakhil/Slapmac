import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Publishes raw acceleration-magnitude samples (in g) at roughly 50-100Hz.
///
/// Reads the built-in accelerometer (a Bosch BMI286, exposed as an
/// `AppleSPUHIDDevice` at usage page 0xFF00 / usage 0x03 — confirmed via
/// `ioreg -p IOService -c IOHIDDevice -l` on Apple Silicon hardware) through
/// the **public** IOHIDDevice API: `IOHIDDeviceCreate`, `IOHIDDeviceOpen`,
/// `IOHIDDeviceSetProperty`, `IOHIDDeviceRegisterInputReportCallback`,
/// `IOHIDDeviceScheduleWithRunLoop`. No private symbols, no dlopen/dlsym.
///
/// The 22-byte raw input report has no public per-field schema (its HID
/// report descriptor declares one opaque byte array), so the impact-sensitive
/// byte offset used in `magnitude(from:length:)` was determined empirically
/// by physically tapping the hardware while dumping raw bytes (see
/// `SLAPSHIFT_DUMP_RAW=1`) — see that method's doc comment for what was
/// tried and ruled out.
final class AccelerometerMonitor {
    typealias SampleHandler = (Double, TimeInterval) -> Void

    private var onSample: SampleHandler?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private static var activeInstance: AccelerometerMonitor?

    private(set) var isRunning = false

    /// True only once a real accelerometer report has actually been observed
    /// flowing through the IOHIDDevice callback — not just that the device
    /// was found and opened, since power-on can silently fail to produce
    /// reports (the real app calls this "sensor not emitting").
    private(set) var didReceiveRealSample = false

    /// Usage page/usage for the built-in accelerometer, confirmed empirically
    /// via ioreg: `DeviceUsagePairs = ({"DeviceUsagePage"=65280,"DeviceUsage"=3})`.
    private static let accelUsagePage = 0xFF00
    private static let accelUsage = 0x03
    private static let reportLength = 22

    /// When set via `SLAPSHIFT_DUMP_RAW=1`, hex-dumps every raw report to
    /// stderr (rate-limited) so the X/Y/Z byte offsets can be discovered by
    /// physically tapping the hardware. Support diagnostic, not for normal use.
    private let dumpRawReports = ProcessInfo.processInfo.environment["SLAPSHIFT_DUMP_RAW"] == "1"
    private var lastDumpAt: TimeInterval = 0

    private var startedAt: TimeInterval = 0
    private var timeoutWorkItem: DispatchWorkItem?

    func start(handler: @escaping SampleHandler) {
        guard !isRunning else { return }
        onSample = handler

        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            isRunning = false
            return
        }

        guard let matchedDevice = AccelerometerMonitor.findAccelerometerDevice() else {
            FileHandle.standardError.write("AccelerometerMonitor: no AppleSPUHIDDevice with accelerometer signature (0xFF00/0x03) found\n".data(using: .utf8)!)
            isRunning = false
            return
        }

        let openResult = IOHIDDeviceOpen(matchedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            FileHandle.standardError.write("AccelerometerMonitor: IOHIDDeviceOpen failed (\(openResult))\n".data(using: .utf8)!)
            isRunning = false
            return
        }

        // Wake the sensor. These are plain CFString property keys passed to
        // the public IOHIDDeviceSetProperty — not private API — confirmed via
        // `strings` on the real app's binary. Value semantics weren't visible
        // in strings output; 1 (powered/enabled) is the natural first guess.
        IOHIDDeviceSetProperty(matchedDevice, "SensorPropertyPowerState" as CFString, NSNumber(value: 1))
        IOHIDDeviceSetProperty(matchedDevice, "SensorPropertyReportingState" as CFString, NSNumber(value: 1))

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: AccelerometerMonitor.reportLength)
        buffer.initialize(repeating: 0, count: AccelerometerMonitor.reportLength)
        reportBuffer = buffer

        device = matchedDevice
        AccelerometerMonitor.activeInstance = self

        IOHIDDeviceRegisterInputReportCallback(
            matchedDevice,
            buffer,
            AccelerometerMonitor.reportLength,
            { context, _, _, _, _, report, reportLength in
                guard let context else { return }
                let monitor = Unmanaged<AccelerometerMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handleReport(report, length: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDDeviceScheduleWithRunLoop(matchedDevice, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        startedAt = CFAbsoluteTimeGetCurrent()
        scheduleNoReportsTimeout()
        isRunning = true
    }

    func stop() {
        isRunning = false
        onSample = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        AccelerometerMonitor.activeInstance = nil
    }

    // MARK: - Device discovery

    /// Iterates IOService entries matching the accelerometer's IOClass, then
    /// double-checks usage page/usage (mirrors the real app's own two-stage
    /// "AppleSPUHIDDevice... accelerometer signature (0xFF00/0x03)" check)
    /// rather than trusting IOHIDManager's broader matching semantics on this
    /// nonstandard sensor class.
    private static func findAccelerometerDevice() -> IOHIDDevice? {
        guard let matchingDict = IOServiceMatching("AppleSPUHIDDevice") else { return nil }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) {
                let usagePage = (IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
                let usage = (IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
                if usagePage == accelUsagePage && usage == accelUsage {
                    IOObjectRelease(service)
                    return candidate
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    // MARK: - Report handling

    private func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        if dumpRawReports {
            dumpRaw(report, length: length)
        }

        guard length >= AccelerometerMonitor.reportLength else { return }
        guard let magnitude = AccelerometerMonitor.magnitude(from: report, length: length) else { return }

        if !didReceiveRealSample {
            didReceiveRealSample = true
        }
        if AccelerometerMonitor.debugMagnitudeLog {
            logMagnitude(magnitude)
        }
        onSample?(magnitude, CFAbsoluteTimeGetCurrent())
    }

    /// Verification-only stderr trace of (magnitude, timestamp), gated behind
    /// `SLAPSHIFT_DEBUG_HID=1`. Used to physically prove real hardware
    /// samples are flowing end-to-end, not just simulated ones.
    private static let debugMagnitudeLog = ProcessInfo.processInfo.environment["SLAPSHIFT_DEBUG_HID"] == "1"
    private var lastMagnitudeLogAt: TimeInterval = 0

    private func logMagnitude(_ magnitude: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMagnitudeLogAt > 0.1 else { return } // ~10Hz
        lastMagnitudeLogAt = now
        FileHandle.standardError.write("REAL SAMPLE: mag=\(String(format: "%.3f", magnitude))g\n".data(using: .utf8)!)
    }

    /// Bytes 18-19 hold a little-endian signed int16, the only field in the
    /// 22-byte report that responds to physical impact. Confirmed empirically
    /// on this hardware (`SLAPSHIFT_DUMP_RAW=1` + physical slap testing):
    /// at rest it drifts gently around ~16000-24000 raw; during a hard slap
    /// it clips hard at the int16 rails (±32768) for ~2s of ringdown, while
    /// every other 16-bit field in the report stays essentially flat. The
    /// three other candidate fields (bytes 6-7, 10-11, 14-15) showed smooth,
    /// continuous drift with zero correlated response to repeated hard slaps
    /// across a 20-second multi-slap test, ruling them out as accelerometer
    /// axes — they're likely gyroscope/calibration/status channels Apple
    /// bundles into the same physical HID report.
    ///
    /// Scale: 16384 LSB/g (a ±2g full-scale range) makes the resting baseline
    /// land at ~1.2g, consistent with gravity on a roughly level deck. A ±2g
    /// range also explains why an ordinary hard slap saturates the channel
    /// outright — this sensor is configured for orientation-sensing, not
    /// shock-sensing, so impacts pin it at the rails rather than reading a
    /// large but unsaturated peak. `SlapDetector`'s five-vote algorithm
    /// operates on relative statistics over a rolling buffer (STA/LTA ratio,
    /// CUSUM, kurtosis, MAD outlier), not absolute peak-g, so a saturated-but-
    /// real transient is still a strong, detectable signal even with this
    /// limited headroom.
    private static func magnitude(from report: UnsafeMutablePointer<UInt8>, length: CFIndex) -> Double? {
        guard length >= 20 else { return nil }
        let raw = Int16(bitPattern: UInt16(report[18]) | (UInt16(report[19]) << 8))
        return abs(Double(raw)) / 16384.0
    }

    private func dumpRaw(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDumpAt > 0.1 else { return } // ~10Hz rate limit
        lastDumpAt = now
        let bytes = (0..<length).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        FileHandle.standardError.write("RAW[\(length)]: \(bytes)\n".data(using: .utf8)!)
    }

    // MARK: - Diagnostics

    /// Mirrors the real app's "0 reports in 3s after start" diagnostic: if
    /// the device opened but never produced a report, that's a distinct,
    /// debuggable failure mode rather than silent inactivity.
    private func scheduleNoReportsTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.didReceiveRealSample else { return }
            FileHandle.standardError.write("AccelerometerMonitor: 0 reports in 3s after start — sensor not emitting\n".data(using: .utf8)!)
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}
