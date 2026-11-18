// [INPUT]: Validated day/metric readings and elapsed animation time.
// [OUTPUT]: Drum positions with eased carries and discrete tooth crossings for sound.
// [POS]: Adds live increments to the current roll without resetting position, velocity or clock.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation
import Observation

@MainActor @Observable
final class HUDAnimator {
    private(set) var reading: HUDReading?
    private(set) var positions: [Double] = []
    private(set) var isRolling = false
    private(set) var generation = 0
    @ObservationIgnored private var motions: [HUDDrumMotion] = []
    @ObservationIgnored private var carryRoll: HUDCarryRoll?
    @ObservationIgnored private var elapsed: TimeInterval = 0

    func receive(_ next: HUDReading, animated: Bool) {
        guard animated, let previous = reading, previous.day == next.day, previous.metric == next.metric,
              let from = previous.value, let to = next.value, to >= from else {
            reading = next; settle(); return
        }
        reading = next
        guard to > from else { return }
        let roll = HUDRoll(from: from, to: to)
        if var carry = carryRoll {
            if carry.extend(to: to, at: elapsed, duration: roll.duration) {
                carryRoll = carry
                positions = carry.positions(at: elapsed)
            } else {
                motions = carry.boundedMotions(to: to, at: elapsed, duration: roll.duration)
                carryRoll = nil
                positions = motions.map(\.start)
            }
        } else if isRolling {
            let addedDigits = roll.starts.count - motions.count
            if addedDigits > 0 {
                motions.insert(contentsOf: Array(repeating: HUDDrumMotion(start: 0, target: 0, startTime: 0,
                                                                          duration: roll.duration, initialSpeed: nil), count: addedDigits), at: 0)
            }
            motions = zip(motions, roll.travel).map { $0.extending(by: $1, at: elapsed, duration: roll.duration) }
            positions = motions.map { $0.sample(at: elapsed).position }
        } else {
            elapsed = 0
            if let carry = HUDCarryRoll(from: from, to: to, duration: roll.duration) {
                carryRoll = carry
                positions = carry.positions(at: 0)
            } else {
                motions = zip(roll.starts, roll.travel).map {
                    HUDDrumMotion(start: $0, target: $0 + $1, startTime: 0, duration: roll.duration, initialSpeed: nil)
                }
                positions = roll.positions(at: 0)
            }
            isRolling = true; generation += 1
        }
    }

    @discardableResult
    func advance(elapsed: TimeInterval) -> Bool {
        guard isRolling else { return false }
        self.elapsed = elapsed
        let next = carryRoll?.positions(at: elapsed) ?? motions.map { $0.sample(at: elapsed).position }
        let finished = carryRoll.map { elapsed >= $0.endTime } ?? motions.allSatisfy { elapsed >= $0.endTime }
        let clicked = zip(positions, next).contains { floor($0) != floor($1) }
        positions = next
        if finished { carryRoll = nil; motions = []; isRolling = false }
        return clicked
    }

    func settle() {
        carryRoll = nil; motions = []; elapsed = 0; isRolling = false; generation += 1
        if let value = reading?.value { positions = HUDRoll(from: value, to: value).positions(at: 1) }
        else { positions = [] }
    }
}
