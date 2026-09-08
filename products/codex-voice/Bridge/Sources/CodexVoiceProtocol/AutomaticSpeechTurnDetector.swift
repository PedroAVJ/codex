import Foundation

/// Keeps response interruption inert until the first response-audio chunk reaches the Watch.
/// Capture may stay warm during provider latency, but only playback can be interrupted.
public struct ResponseBargeInGate: Equatable, Sendable {
    public static let initialPlaybackSettlingMilliseconds = 450

    public enum State: Equatable, Sendable {
        case inactive
        case waitingForFirstAudio
        case playbackStarted
    }

    public enum SpeechDecision: Equatable, Sendable {
        case ignore
        case ignoreBeforeOutput
        case ignoreInitialPlayback
        case ignorePlaybackEcho
        case interruptPlayback
    }

    public private(set) var state: State = .inactive
    public private(set) var detectorEpoch: UInt64 = 0

    public init() {}

    public mutating func committed() {
        state = .waitingForFirstAudio
    }

    /// Returns true only for the transition that should reset and arm playback barge-in.
    @discardableResult
    public mutating func receivedFirstAudio() -> Bool {
        guard state != .playbackStarted else { return false }
        state = .playbackStarted
        return true
    }

    public func speechDecision(
        playbackAgeMilliseconds: Int = .max,
        likelyPlaybackEcho: Bool = false
    ) -> SpeechDecision {
        switch state {
        case .inactive:
            .ignore
        case .waitingForFirstAudio:
            .ignoreBeforeOutput
        case .playbackStarted:
            if playbackAgeMilliseconds < Self.initialPlaybackSettlingMilliseconds {
                .ignoreInitialPlayback
            } else if likelyPlaybackEcho {
                .ignorePlaybackEcho
            } else {
                .interruptPlayback
            }
        }
    }

    /// Invalidates callbacks from the detector's previous purpose and returns the new epoch.
    @discardableResult
    public mutating func rearmedDetector() -> UInt64 {
        detectorEpoch &+= 1
        return detectorEpoch
    }

    public func isCurrentDetectorEpoch(_ epoch: UInt64) -> Bool {
        detectorEpoch == epoch
    }

    public mutating func reset() {
        state = .inactive
        detectorEpoch &+= 1
    }
}

/// Compares processed microphone PCM with the response PCM currently playing on the Watch.
/// Apple's voice-processing path remains the primary echo canceller. This matcher is the
/// second-stage double-talk guard: it rejects residual speaker audio without raising the
/// microphone threshold for a real nearby speaker.
public struct PlaybackEchoMatcher: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var sampleRate: Int
        public var maximumRetainedReferenceSeconds: Double
        public var maximumFutureComparisonSeconds: Double
        public var retainedPlayedReferenceSeconds: Double
        public var maximumCaptureSeconds: Double
        public var minimumComparedSamples: Int
        public var waveformDownsampleFactor: Int
        public var envelopeFrameSamples: Int
        public var waveformThreshold: Double
        public var combinedWaveformThreshold: Double
        public var envelopeThreshold: Double

        public init(
            sampleRate: Int = 24_000,
            maximumRetainedReferenceSeconds: Double = 45,
            maximumFutureComparisonSeconds: Double = 3,
            retainedPlayedReferenceSeconds: Double = 0.65,
            maximumCaptureSeconds: Double = 0.35,
            minimumComparedSamples: Int = 1_200,
            waveformDownsampleFactor: Int = 12,
            envelopeFrameSamples: Int = 240,
            waveformThreshold: Double = 0.48,
            combinedWaveformThreshold: Double = 0.34,
            envelopeThreshold: Double = 0.84
        ) {
            self.sampleRate = sampleRate
            self.maximumRetainedReferenceSeconds = maximumRetainedReferenceSeconds
            self.maximumFutureComparisonSeconds = maximumFutureComparisonSeconds
            self.retainedPlayedReferenceSeconds = retainedPlayedReferenceSeconds
            self.maximumCaptureSeconds = maximumCaptureSeconds
            self.minimumComparedSamples = minimumComparedSamples
            self.waveformDownsampleFactor = waveformDownsampleFactor
            self.envelopeFrameSamples = envelopeFrameSamples
            self.waveformThreshold = waveformThreshold
            self.combinedWaveformThreshold = combinedWaveformThreshold
            self.envelopeThreshold = envelopeThreshold
        }
    }

    public struct Match: Equatable, Sendable {
        public let isLikelyEcho: Bool
        public let waveformCorrelation: Double
        public let envelopeCorrelation: Double
        public let referenceSamples: Int
        public let capturedSamples: Int

        public init(
            isLikelyEcho: Bool,
            waveformCorrelation: Double,
            envelopeCorrelation: Double,
            referenceSamples: Int,
            capturedSamples: Int
        ) {
            self.isLikelyEcho = isLikelyEcho
            self.waveformCorrelation = waveformCorrelation
            self.envelopeCorrelation = envelopeCorrelation
            self.referenceSamples = referenceSamples
            self.capturedSamples = capturedSamples
        }
    }

    private let configuration: Configuration
    private var referencePCM = Data()
    private var playedReferenceSamples = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func appendReference(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        let evenByteCount = pcm.count - (pcm.count % MemoryLayout<Int16>.size)
        guard evenByteCount > 0 else { return }
        let maximumBytes = Int(
            Double(configuration.sampleRate * MemoryLayout<Int16>.size)
                * configuration.maximumRetainedReferenceSeconds
        )
        let availableBytes = max(0, maximumBytes - referencePCM.count)
        referencePCM.append(pcm.prefix(min(evenByteCount, availableBytes)))
    }

    public mutating func advancePlayback(by sourceSamples: Int) {
        guard sourceSamples > 0 else { return }
        playedReferenceSamples = min(
            referencePCM.count / MemoryLayout<Int16>.size,
            playedReferenceSamples + sourceSamples
        )
        let retainedPlayedSamples = Int(
            Double(configuration.sampleRate) * configuration.retainedPlayedReferenceSeconds
        )
        guard playedReferenceSamples > retainedPlayedSamples else { return }
        let samplesToDiscard = playedReferenceSamples - retainedPlayedSamples
        referencePCM.removeFirst(samplesToDiscard * MemoryLayout<Int16>.size)
        playedReferenceSamples -= samplesToDiscard
    }

    public mutating func reset() {
        referencePCM.removeAll(keepingCapacity: true)
        playedReferenceSamples = 0
    }

    public func match(capturedPCM: Data) -> Match {
        let futureComparisonSamples = Int(
            Double(configuration.sampleRate) * configuration.maximumFutureComparisonSeconds
        )
        let comparisonSamples = min(
            referencePCM.count / MemoryLayout<Int16>.size,
            playedReferenceSamples + futureComparisonSamples
        )
        let allReferenceSamples = Self.samples(
            in: referencePCM.prefix(comparisonSamples * MemoryLayout<Int16>.size)
        )
        let allCapturedSamples = Self.samples(in: capturedPCM)
        let maximumCaptureSamples = Int(
            Double(configuration.sampleRate) * configuration.maximumCaptureSeconds
        )
        let capturedSamples = Array(allCapturedSamples.suffix(maximumCaptureSamples))

        guard capturedSamples.count >= configuration.minimumComparedSamples,
              allReferenceSamples.count >= capturedSamples.count else {
            return Match(
                isLikelyEcho: false,
                waveformCorrelation: 0,
                envelopeCorrelation: 0,
                referenceSamples: allReferenceSamples.count,
                capturedSamples: capturedSamples.count
            )
        }

        let referenceWaveform = Self.blockAverages(
            allReferenceSamples,
            blockSize: configuration.waveformDownsampleFactor,
            absolute: false
        )
        let capturedWaveform = Self.blockAverages(
            capturedSamples,
            blockSize: configuration.waveformDownsampleFactor,
            absolute: false
        )
        let waveformCorrelation = Self.maximumNormalizedCorrelation(
            candidate: capturedWaveform,
            reference: referenceWaveform
        )

        let referenceEnvelope = Self.blockAverages(
            allReferenceSamples,
            blockSize: configuration.envelopeFrameSamples,
            absolute: true
        )
        let capturedEnvelope = Self.blockAverages(
            capturedSamples,
            blockSize: configuration.envelopeFrameSamples,
            absolute: true
        )
        let envelopeCorrelation = Self.maximumNormalizedCorrelation(
            candidate: capturedEnvelope,
            reference: referenceEnvelope
        )
        let isLikelyEcho = waveformCorrelation >= configuration.waveformThreshold
            || (waveformCorrelation >= configuration.combinedWaveformThreshold
                && envelopeCorrelation >= configuration.envelopeThreshold)

        return Match(
            isLikelyEcho: isLikelyEcho,
            waveformCorrelation: waveformCorrelation,
            envelopeCorrelation: envelopeCorrelation,
            referenceSamples: allReferenceSamples.count,
            capturedSamples: capturedSamples.count
        )
    }

    private static func samples(in data: Data) -> [Double] {
        data.withUnsafeBytes { rawBuffer in
            rawBuffer.bindMemory(to: Int16.self).map {
                Double(Int16(littleEndian: $0))
            }
        }
    }

    private static func blockAverages(
        _ samples: [Double],
        blockSize: Int,
        absolute: Bool
    ) -> [Double] {
        guard blockSize > 0, samples.count >= blockSize else { return [] }
        var result = [Double]()
        result.reserveCapacity(samples.count / blockSize)
        var offset = 0
        while offset + blockSize <= samples.count {
            var sum = 0.0
            for sample in samples[offset..<(offset + blockSize)] {
                sum += absolute ? abs(sample) : sample
            }
            result.append(sum / Double(blockSize))
            offset += blockSize
        }
        return result
    }

    private static func maximumNormalizedCorrelation(
        candidate: [Double],
        reference: [Double]
    ) -> Double {
        guard candidate.count >= 4, reference.count >= candidate.count else { return 0 }
        let candidateMean = candidate.reduce(0, +) / Double(candidate.count)
        let centeredCandidate = candidate.map { $0 - candidateMean }
        let candidateEnergy = centeredCandidate.reduce(0) { $0 + ($1 * $1) }
        guard candidateEnergy > 1 else { return 0 }

        var referencePrefixSum = [Double](repeating: 0, count: reference.count + 1)
        var referencePrefixSquares = [Double](repeating: 0, count: reference.count + 1)
        for index in reference.indices {
            referencePrefixSum[index + 1] = referencePrefixSum[index] + reference[index]
            referencePrefixSquares[index + 1] = referencePrefixSquares[index]
                + (reference[index] * reference[index])
        }

        var maximum = 0.0
        let count = candidate.count
        for offset in 0...(reference.count - count) {
            let referenceSum = referencePrefixSum[offset + count] - referencePrefixSum[offset]
            let referenceSquares = referencePrefixSquares[offset + count]
                - referencePrefixSquares[offset]
            let referenceEnergy = referenceSquares
                - (referenceSum * referenceSum / Double(count))
            guard referenceEnergy > 1 else { continue }

            var dotProduct = 0.0
            for index in 0..<count {
                dotProduct += centeredCandidate[index] * reference[offset + index]
            }
            let correlation = abs(dotProduct) / sqrt(candidateEnergy * referenceEnergy)
            maximum = max(maximum, min(1, correlation))
        }
        return maximum
    }
}

/// Energy-based turn detection tuned for the processed microphone signal emitted by Apple Watch.
/// The detector intentionally favors catching quiet speech over suppressing every false start: an
/// occasional short turn is recoverable, while a missed utterance makes the voice surface appear dead.
public struct AutomaticSpeechTurnDetector: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var sampleRate: Int
        public var preRollSeconds: Double
        public var minimumSpeechSeconds: Double
        public var endSilenceSeconds: Double
        public var maximumTurnSeconds: Double
        public var initialNoiseFloorRMS: Double
        public var minimumStartRMS: Double
        public var minimumContinueRMS: Double
        public var transientPeak: Double
        public var hotFramesToStart: Int

        public init(
            sampleRate: Int = 24_000,
            preRollSeconds: Double = 0.65,
            minimumSpeechSeconds: Double = 0.20,
            endSilenceSeconds: Double = 0.65,
            maximumTurnSeconds: Double = 25,
            initialNoiseFloorRMS: Double = 72,
            minimumStartRMS: Double = 180,
            minimumContinueRMS: Double = 115,
            transientPeak: Double = 760,
            hotFramesToStart: Int = 2
        ) {
            self.sampleRate = sampleRate
            self.preRollSeconds = preRollSeconds
            self.minimumSpeechSeconds = minimumSpeechSeconds
            self.endSilenceSeconds = endSilenceSeconds
            self.maximumTurnSeconds = maximumTurnSeconds
            self.initialNoiseFloorRMS = initialNoiseFloorRMS
            self.minimumStartRMS = minimumStartRMS
            self.minimumContinueRMS = minimumContinueRMS
            self.transientPeak = transientPeak
            self.hotFramesToStart = hotFramesToStart
        }
    }

    public enum Event: Equatable, Sendable {
        case started(preRoll: Data)
        case ended
    }

    public struct Snapshot: Equatable, Sendable {
        public let sampleCount: Int
        public let rms: Double
        public let peak: Double
        public let noiseFloorRMS: Double
        public let startThresholdRMS: Double
        public let continueThresholdRMS: Double
        public let hasSpeech: Bool
    }

    public struct Observation: Equatable, Sendable {
        public let event: Event?
        public let snapshot: Snapshot
    }

    private let configuration: Configuration
    private let preRollBytes: Int
    private let minimumSpeechSamples: Int
    private let endSilenceSamples: Int
    private let maximumTurnSamples: Int

    private var noiseFloorRMS: Double
    private var consecutiveHotFrames = 0
    private var speechSamples = 0
    private var silenceSamples = 0
    private var hasSpeech = false
    private var preRoll = Data()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        preRollBytes = Int(Double(configuration.sampleRate * MemoryLayout<Int16>.size)
            * configuration.preRollSeconds)
        minimumSpeechSamples = Int(Double(configuration.sampleRate) * configuration.minimumSpeechSeconds)
        endSilenceSamples = Int(Double(configuration.sampleRate) * configuration.endSilenceSeconds)
        maximumTurnSamples = Int(Double(configuration.sampleRate) * configuration.maximumTurnSeconds)
        noiseFloorRMS = configuration.initialNoiseFloorRMS
    }

    public mutating func consume(_ data: Data) -> Observation? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }

        preRoll.append(data)
        if preRoll.count > preRollBytes {
            preRoll.removeFirst(preRoll.count - preRollBytes)
        }

        let energy = Self.energy(in: data)
        let startThreshold = max(configuration.minimumStartRMS, noiseFloorRMS * 1.85)
        let continueThreshold = max(configuration.minimumContinueRMS, noiseFloorRMS * 1.28)
        var event: Event?

        if !hasSpeech {
            let isHot = energy.rms >= startThreshold
                || (energy.rms >= configuration.minimumContinueRMS
                    && energy.peak >= max(configuration.transientPeak, startThreshold * 2.4))

            if !isHot {
                // Follow quieter rooms quickly and louder rooms cautiously. Capping the tracked
                // floor prevents a brief bump or wrist movement from making subsequent speech inaudible.
                let alpha = energy.rms < noiseFloorRMS ? 0.12 : 0.012
                noiseFloorRMS += (min(320, energy.rms) - noiseFloorRMS) * alpha
            }

            consecutiveHotFrames = isHot
                ? consecutiveHotFrames + 1
                : max(0, consecutiveHotFrames - 1)
            if consecutiveHotFrames >= configuration.hotFramesToStart {
                hasSpeech = true
                speechSamples = sampleCount * consecutiveHotFrames
                silenceSamples = 0
                event = .started(preRoll: preRoll)
            }
        } else {
            speechSamples += sampleCount
            let continues = energy.rms >= continueThreshold
                || energy.peak >= max(configuration.transientPeak * 0.72, continueThreshold * 2.2)
            silenceSamples = continues ? 0 : silenceSamples + sampleCount

            if speechSamples >= maximumTurnSamples
                || (speechSamples >= minimumSpeechSamples && silenceSamples >= endSilenceSamples) {
                event = .ended
            }
        }

        return Observation(
            event: event,
            snapshot: Snapshot(
                sampleCount: sampleCount,
                rms: energy.rms,
                peak: energy.peak,
                noiseFloorRMS: noiseFloorRMS,
                startThresholdRMS: startThreshold,
                continueThresholdRMS: continueThreshold,
                hasSpeech: hasSpeech
            )
        )
    }

    private static func energy(in data: Data) -> (rms: Double, peak: Double) {
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return (0, 0) }

            var sumOfSquares = 0.0
            var peak = 0.0
            for sample in samples {
                let value = Double(Int32(sample))
                sumOfSquares += value * value
                peak = max(peak, abs(value))
            }
            return (sqrt(sumOfSquares / Double(samples.count)), peak)
        }
    }
}
