// [INPUT]: Validated day/metric readings and elapsed animation time.
// [OUTPUT]: Drum positions and discrete tooth crossings for synchronized sound.
// [POS]: Coalesces live updates without restarting an in-flight roll.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation
import Observation

@MainActor @Observable
final class HUDAnimator {
    private(set) var reading: HUDReading?
    private(set) var positions: [Double] = []
    private(set) var isRolling = false
    private(set) var generation = 0
    @ObservationIgnored private var roll: HUDRoll?
    @ObservationIgnored private var pending: HUDReading?
    @ObservationIgnored private var lastTooth = 0

    func receive(_ next: HUDReading, animated: Bool) {
        guard animated, let previous = reading, previous.day == next.day, previous.metric == next.metric,
              let from = previous.value, let to = next.value, to >= from else {
            reading = next; pending = nil; settle(); return
        }
        if isRolling { pending = next; return }
        reading = next
        guard to > from else { return }
        roll = HUDRoll(from: from, to: to)
        positions = roll!.positions(at: 0)
        lastTooth = 0; isRolling = true; generation += 1
    }

    @discardableResult
    func advance(elapsed: TimeInterval) -> Bool {
        guard let roll else { return false }
        let time = min(1, elapsed / roll.duration)
        positions = roll.positions(at: time)
        let tooth = Int(floor(roll.maxTravel * HUDRoll.curve(time).progress))
        let clicked = tooth != lastTooth
        lastTooth = tooth
        if time >= 1 {
            self.roll = nil; isRolling = false
            if let next = pending { pending = nil; receive(next, animated: true) }
        }
        return clicked
    }

    func settle() {
        if let pending { reading = pending }
        pending = nil; roll = nil; isRolling = false; generation += 1
        if let value = reading?.value { positions = HUDRoll(from: value, to: value).positions(at: 1) }
        else { positions = [] }
    }
}
