import Foundation

/// Timing for one spin-chair pass: when to take photos and what to say.
struct SpinPlan: Sendable, Equatable {
    /// How long one full turn should take.
    var spinDuration: TimeInterval = 30
    /// Time between photos.
    var shotInterval: TimeInterval = 0.4
    /// Seconds to get seated after tapping Start.
    var countdown: Int = 5

    static let durations: [TimeInterval] = [20, 30, 45]

    struct Cue: Sendable, Equatable {
        let time: TimeInterval
        let text: String
    }

    /// Spoken cues during a spin, by seconds since the spin started.
    var cues: [Cue] {
        [
            Cue(time: 0, text: "Start turning slowly. Keep your head still."),
            Cue(time: spinDuration * 0.25, text: "Keep going."),
            Cue(time: spinDuration * 0.5, text: "Halfway."),
            Cue(time: spinDuration * 0.8, text: "Almost there."),
            Cue(time: spinDuration, text: "Stop."),
        ]
    }

    /// Which of the 30 coverage slices a photo at `elapsed` seconds belongs to.
    func slice(at elapsed: TimeInterval) -> Int {
        let fraction = max(0, min(0.9999, elapsed / spinDuration))
        return Int(fraction * Double(CoverageTracker.slices))
    }

    /// Roughly how many photos one pass takes.
    var expectedShots: Int { Int(spinDuration / shotInterval) }

    /// 0...1 progress of a spin.
    func progress(at elapsed: TimeInterval) -> Double {
        max(0, min(1, elapsed / spinDuration))
    }
}
