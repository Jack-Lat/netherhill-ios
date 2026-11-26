import Foundation

public enum NetherhillVoicePreset: Int, CaseIterable {
    case off = 0
    case nasaFiFi = 1
    case studioEQ = 2
    case deepBass = 3

    private static let defaultsKey = "netherhill.voice.preset"

    public static var current: NetherhillVoicePreset {
        get {
            let raw = UserDefaults.standard.integer(forKey: defaultsKey)
            return NetherhillVoicePreset(rawValue: raw) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    public var title: String {
        switch self {
        case .off: return "Выкл (Оригинал)"
        case .nasaFiFi: return "NASA_FiFi (-1.04 st + EQ)"
        case .studioEQ: return "Студийный (Voice HQ)"
        case .deepBass: return "Глубокий бас (-2.5 st)"
        }
    }
}

private struct NhBiquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highPass(fs: Float, fc: Float, q: Float = 0.707) -> NhBiquad {
        let w0 = 2.0 * Float.pi * fc / fs
        let cosw = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha
        return NhBiquad(
            b0: ((1.0 + cosw) * 0.5) / a0,
            b1: -(1.0 + cosw) / a0,
            b2: ((1.0 + cosw) * 0.5) / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    static func peaking(fs: Float, fc: Float, q: Float, gainDb: Float) -> NhBiquad {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Float.pi * fc / fs
        let cosw = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha / a
        return NhBiquad(
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cosw) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha / a) / a0
        )
    }
}

public final class NetherhillVoiceProcessor {
    private let preset: NetherhillVoicePreset
    private var hp: NhBiquad
    private var eqLow: NhBiquad
    private var eqMidCut: NhBiquad
    private var eqPresence: NhBiquad

    // Noise gate state (-50 dB threshold)
    private var gateEnv: Float = 0.0
    private var gateGain: Float = 0.0

    // Dual-head ring-buffer pitch shifter (preserves duration)
    private let ringSize = 2048
    private var ring: [Float]
    private var writeIdx = 0
    private var phase: Float = 0.0
    private let pitchRatio: Float

    public init(preset: NetherhillVoicePreset, sampleRate: Float = 16000.0) {
        self.preset = preset
        self.hp = NhBiquad.highPass(fs: sampleRate, fc: 75.0)
        self.eqLow = NhBiquad.peaking(fs: sampleRate, fc: 115.0, q: 0.9, gainDb: 3.5)
        self.eqMidCut = NhBiquad.peaking(fs: sampleRate, fc: 400.0, q: 1.2, gainDb: -3.0)
        self.eqPresence = NhBiquad.peaking(fs: sampleRate, fc: 3200.0, q: 1.1, gainDb: 2.5)
        self.ring = [Float](repeating: 0.0, count: 2048)

        switch preset {
        case .nasaFiFi:
            self.pitchRatio = pow(2.0, -1.04 / 12.0)
        case .deepBass:
            self.pitchRatio = pow(2.0, -2.5 / 12.0)
        case .off, .studioEQ:
            self.pitchRatio = 1.0
        }
    }

    public func processInPlace(samples: UnsafeMutablePointer<Int16>, count: Int) {
        guard self.preset != .off, count > 0 else { return }
        let threshold: Float = 0.00316 // ~ -50 dB
        let windowLen: Float = 512.0
        let limitCeiling: Float = 0.89125 // -1 dB

        for i in 0 ..< count {
            var x = Float(samples[i]) / 32768.0

            // 1. Noise Gate (-50 dB)
            let absX = abs(x)
            gateEnv = absX > gateEnv ? (0.15 * absX + 0.85 * gateEnv) : (0.002 * absX + 0.998 * gateEnv)
            let targetGate: Float = gateEnv >= threshold ? 1.0 : 0.0
            gateGain += (targetGate - gateGain) * (targetGate > gateGain ? 0.15 : 0.01)
            x *= gateGain

            // 2. Voice Mode HQ EQ
            x = hp.process(x)
            x = eqLow.process(x)
            x = eqMidCut.process(x)
            x = eqPresence.process(x)

            // 3. Pitch shift (if active)
            if pitchRatio != 1.0 {
                ring[writeIdx] = x
                let p1 = phase
                var p2 = phase + 0.5
                if p2 >= 1.0 { p2 -= 1.0 }

                let d1 = p1 * windowLen
                let d2 = p2 * windowLen
                let s1 = readInterpolated(delay: d1)
                let s2 = readInterpolated(delay: d2)

                let w1 = 0.5 * (1.0 - cos(2.0 * Float.pi * p1))
                let w2 = 0.5 * (1.0 - cos(2.0 * Float.pi * p2))
                x = s1 * w1 + s2 * w2

                phase += (1.0 - pitchRatio) / windowLen
                if phase >= 1.0 { phase -= 1.0 }
                if phase < 0.0 { phase += 1.0 }
                writeIdx = (writeIdx + 1) & (ringSize - 1)
            }

            // 4. Safety limiter -1 dB
            x = limitCeiling * tanh(x / limitCeiling)

            let scaled = max(-32767.0, min(32767.0, x * 32768.0))
            samples[i] = Int16(scaled)
        }
    }

    private func readInterpolated(delay: Float) -> Float {
        let mask = ringSize - 1
        let dInt = Int(delay)
        let frac = delay - Float(dInt)
        let idx0 = (writeIdx - dInt + ringSize) & mask
        let idx1 = (idx0 - 1 + ringSize) & mask
        return ring[idx0] * (1.0 - frac) + ring[idx1] * frac
    }
}
