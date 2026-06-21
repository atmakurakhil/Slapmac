import Foundation
import Combine

/// Detects a single "slap" impulse from a rolling buffer of accelerometer
/// magnitude samples using five independent signal-processing votes, then
/// debounces repeated slaps into a 1/2/3 consecutive-slap count.
final class SlapDetector: ObservableObject {
    @Published private(set) var lastFiredSlapCount: Int = 0
    @Published private(set) var lastFiredAt: Date?
    /// True only while a confirmed slap is genuinely ambiguous (an enabled slot exists
    /// for the next higher count) and we're waiting out the multi-slap window to see if
    /// another slap follows. False (and the slot fires immediately) whenever there's no
    /// possible follow-up slot, so a 1-slap-only setup never pays the window's latency.
    @Published private(set) var isArmedForMoreSlaps: Bool = false
    /// Most recent raw acceleration magnitude in g, for the live calibration meter.
    @Published private(set) var liveMagnitudeG: Double = 1.0
    /// Highest magnitude seen since the meter was last reset, for the meter's peak marker.
    @Published private(set) var peakMagnitudeG: Double = 1.0

    /// Visual threshold line shown in the calibration meter; lower sensitivity
    /// values require a harder hit before the votes below will agree.
    var thresholdG: Double {
        1.2 + (1 - configStore.config.sensitivity) * 1.3
    }

    private let monitor = AccelerometerMonitor()
    private let configStore: ConfigStore

    private var buffer: [Double] = []
    private let bufferCapacity = 200 // ~2 seconds at 100Hz

    private var lastSlapAt: TimeInterval = 0
    private var pendingSlapCount: Int = 0
    private var multiSlapTimer: Timer?

    private let minInterSlapGap: TimeInterval = 0.15 // refractory period to avoid double counting one impact

    var onSlot: ((Int) -> Void)?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// True only once real accelerometer samples have actually been observed
    /// flowing through the private HID path — not just that the symbols
    /// resolved, since the usage-page/usage guesses can be wrong per macOS build.
    var isHardwareAvailable: Bool { monitor.didReceiveRealSample }

    func start() {
        monitor.start { [weak self] magnitude, timestamp in
            self?.ingest(magnitude: magnitude, timestamp: timestamp)
        }
    }

    func stop() {
        monitor.stop()
    }

    /// Directly fires a confirmed slap, bypassing the voting buffer. Used by
    /// the "Simulate Slap" UI and the onboarding calibration steps — a manual
    /// assertion that a slap happened shouldn't have to satisfy the same
    /// 16-sample statistical buffer that real accelerometer noise must clear.
    func simulateSlap() {
        liveMagnitudeG = 3.5
        if liveMagnitudeG > peakMagnitudeG { peakMagnitudeG = liveMagnitudeG }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSlapAt > minInterSlapGap else { return }
        lastSlapAt = now
        registerSlap(at: now)
    }

    func resetPeakMeter() {
        peakMagnitudeG = liveMagnitudeG
    }

    /// Fires `count` simulated slaps spaced `spacing` apart, each scheduled
    /// only after the previous one actually runs. Independent absolute
    /// `asyncAfter` deadlines are subject to system timer coalescing, which
    /// can land two "200ms apart" calls back-to-back and trip the refractory
    /// guard meant for one impact's vibration ringing — chaining avoids that.
    func simulateSlaps(count: Int, spacing: TimeInterval = 0.22) {
        guard count > 0 else { return }
        simulateSlap()
        guard count > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + spacing) { [weak self] in
            self?.simulateSlaps(count: count - 1, spacing: spacing)
        }
    }

    // MARK: - Sample ingestion

    private func ingest(magnitude: Double, timestamp: TimeInterval) {
        liveMagnitudeG = magnitude
        if magnitude > peakMagnitudeG { peakMagnitudeG = magnitude }

        buffer.append(magnitude)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
        guard buffer.count >= 16 else { return }
        guard timestamp - lastSlapAt > minInterSlapGap else { return }

        let sensitivity = configStore.config.sensitivity // 0 (least) ... 1 (most)
        let votes = SlapVoting.evaluate(buffer: buffer, sensitivity: sensitivity)

        // Require a majority of the five algorithms to agree (>= 3 of 5).
        if votes.votesInFavor >= 3 {
            lastSlapAt = timestamp
            registerSlap(at: timestamp)
        }
    }

    // MARK: - Consecutive slap counting

    private func registerSlap(at timestamp: TimeInterval) {
        pendingSlapCount = min(pendingSlapCount + 1, 3)
        multiSlapTimer?.invalidate()
        if ProcessInfo.processInfo.environment["SLAPSHIFT_DEBUG_SEQ"] == "1" {
            FileHandle.standardError.write("registerSlap t=\(timestamp) pendingSlapCount=\(pendingSlapCount)\n".data(using: .utf8)!)
        }

        // No reason to wait out the window if there's no way a follow-up slap could
        // change which slot fires: either we've hit the max count, or no enabled slot
        // is bound to the next higher count. Firing immediately is what makes a 1-slap
        // action feel instant instead of always eating the window's latency.
        guard pendingSlapCount < 3, configStore.slot(forSlapCount: pendingSlapCount + 1) != nil else {
            isArmedForMoreSlaps = false
            finalizeSlapSequence()
            return
        }

        isArmedForMoreSlaps = true
        let window = configStore.config.multiSlapWindowSeconds
        multiSlapTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            self?.isArmedForMoreSlaps = false
            self?.finalizeSlapSequence()
        }
    }

    private func finalizeSlapSequence() {
        let count = pendingSlapCount
        pendingSlapCount = 0
        guard count > 0 else { return }
        if ProcessInfo.processInfo.environment["SLAPSHIFT_DEBUG_SEQ"] == "1" {
            FileHandle.standardError.write("finalizeSlapSequence count=\(count) at \(CFAbsoluteTimeGetCurrent())\n".data(using: .utf8)!)
        }

        configStore.incrementLifetimeSlapCount()
        lastFiredSlapCount = count
        lastFiredAt = Date()
        onSlot?(count)
    }
}

/// Five independent statistical votes on whether the buffer's tail contains a slap impulse.
struct SlapVoting {
    struct Result {
        let votesInFavor: Int
    }

    static func evaluate(buffer: [Double], sensitivity: Double) -> Result {
        // Sensitivity scales how aggressively each threshold trips: higher
        // sensitivity = lower thresholds = easier to trigger.
        let thresholdScale = 1.6 - sensitivity * 1.1 // ranges ~0.5 (high sens) ... 1.6 (low sens)

        var votes = 0
        if highPassImpulse(buffer, scale: thresholdScale) { votes += 1 }
        if staLtaRatio(buffer, scale: thresholdScale) { votes += 1 }
        if cusumShift(buffer, scale: thresholdScale) { votes += 1 }
        if kurtosisSpike(buffer, scale: thresholdScale) { votes += 1 }
        if madOutlier(buffer, scale: thresholdScale) { votes += 1 }
        return Result(votesInFavor: votes)
    }

    /// 1) High-pass filter: removes the ~1g gravity DC offset, flags a sharp residual spike.
    private static func highPassImpulse(_ buffer: [Double], scale: Double) -> Bool {
        guard buffer.count >= 8 else { return false }
        let alpha = 0.85
        var filtered: Double = 0
        var prevRaw = buffer[buffer.count - 8]
        var maxResidual: Double = 0
        for sample in buffer.suffix(8) {
            filtered = alpha * (filtered + sample - prevRaw)
            prevRaw = sample
            maxResidual = max(maxResidual, abs(filtered))
        }
        return maxResidual > 0.8 * scale
    }

    /// 2) STA/LTA ratio: short-term average energy vs. long-term average energy.
    private static func staLtaRatio(_ buffer: [Double], scale: Double) -> Bool {
        let shortWindow = min(8, buffer.count)
        let longWindow = min(80, buffer.count)
        guard longWindow > shortWindow else { return false }
        let sta = average(buffer.suffix(shortWindow).map { $0 * $0 })
        let lta = average(buffer.suffix(longWindow).map { $0 * $0 })
        guard lta > 0.0001 else { return false }
        return (sta / lta) > 4.0 * scale
    }

    /// 3) CUSUM: cumulative deviation from the running mean exceeds a threshold.
    private static func cusumShift(_ buffer: [Double], scale: Double) -> Bool {
        let window = buffer.suffix(min(60, buffer.count))
        let mean = average(Array(window))
        var cusumPos: Double = 0
        var maxCusum: Double = 0
        for sample in window {
            cusumPos = max(0, cusumPos + (sample - mean) - 0.05)
            maxCusum = max(maxCusum, cusumPos)
        }
        return maxCusum > 0.9 * scale
    }

    /// 4) Kurtosis: typing/ambient vibration is roughly Gaussian (kurtosis ~3); slaps produce sharp,
    /// leptokurtic spikes with much higher kurtosis.
    private static func kurtosisSpike(_ buffer: [Double], scale: Double) -> Bool {
        let window = Array(buffer.suffix(min(60, buffer.count)))
        guard window.count >= 16 else { return false }
        let mean = average(window)
        let variance = average(window.map { ($0 - mean) * ($0 - mean) })
        guard variance > 0.0001 else { return false }
        let fourth = average(window.map { pow($0 - mean, 4) })
        let kurtosis = fourth / (variance * variance)
        return kurtosis > 6.0 * scale
    }

    /// 5) Median Absolute Deviation outlier: flags samples far outside the robust spread of recent history.
    private static func madOutlier(_ buffer: [Double], scale: Double) -> Bool {
        let window = Array(buffer.suffix(min(60, buffer.count)))
        guard window.count >= 16, let latest = buffer.last else { return false }
        let sorted = window.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = window.map { abs($0 - median) }.sorted()
        let mad = max(deviations[deviations.count / 2], 0.01)
        let robustZ = abs(latest - median) / (1.4826 * mad)
        return robustZ > 5.0 * scale
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
