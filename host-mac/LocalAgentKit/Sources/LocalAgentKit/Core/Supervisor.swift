import Foundation

/// Watches the run for signs that the model is stuck and decides what changes
/// next. The model never has to notice it's looping; the harness does.
public struct Supervisor: Sendable {
    public enum Directive: Sendable, Equatable {
        case proceed
        case nudge(String)
        case showScreenshot(String)
        case replan(String)
        case askForHelp(String)
    }

    public var replanAfterNoEffect = 4
    public var helpAfterNoEffect = 7
    public var stepsPerPlanItem = 14
    public var maximumReplans = 2

    public private(set) var replans = 0
    private var scenesSeen: [String: Int] = [:]

    public init() {}

    /// Called once per step before asking the model.
    public mutating func inspect(records: [WorkingMemory.Record], stepsSincePlanProgress: Int, sceneFingerprint: String) -> Directive {
        scenesSeen[sceneFingerprint, default: 0] += 1
        let noEffect = Self.noEffectStreak(records)

        if noEffect >= helpAfterNoEffect {
            return .askForHelp("I've tried \(noEffect) things and nothing changes on screen.")
        }
        let looping = Self.isStuckRepeating(records)
        if noEffect >= replanAfterNoEffect || stepsSincePlanProgress >= stepsPerPlanItem || looping {
            if replans < maximumReplans {
                replans += 1
                if noEffect >= replanAfterNoEffect { return .replan("The last \(noEffect) actions changed nothing.") }
                return .replan(looping ? "The same few actions keep repeating without getting anywhere."
                    : "This step has taken \(stepsSincePlanProgress) actions without finishing.")
            }
            return .askForHelp(noEffect >= replanAfterNoEffect
                ? "I've changed approach and still can't make progress here."
                : "This is taking far more steps than it should, even after changing approach.")
        }
        if noEffect >= 2 {
            return .showScreenshot("Your last \(noEffect) actions changed nothing. Look at the screenshot and try something different: a menu, a keyboard shortcut, or another element.")
        }
        if Self.isOscillating(records) || Self.isRepeatingAction(records) {
            return .showScreenshot("You are going back and forth between the same actions. Stop and take a different route to the goal.")
        }
        if (scenesSeen[sceneFingerprint] ?? 0) >= 4 {
            return .nudge("You keep returning to this same screen. What you've been doing isn't working; try another way.")
        }
        return .proceed
    }

    public mutating func resetSceneMemory() { scenesSeen.removeAll() }

    static func noEffectStreak(_ records: [WorkingMemory.Record]) -> Int {
        var streak = 0
        for record in records.reversed() {
            if record.hadEffect { break }
            streak += 1
        }
        return streak
    }

    /// The same action three or more times recently, even if each one "did" something.
    /// Opening File > New over and over changes the screen every time and gets nowhere.
    static func isRepeatingAction(_ records: [WorkingMemory.Record]) -> Bool {
        var counts: [String: Int] = [:]
        for record in records.suffix(8) { counts[record.fingerprint, default: 0] += 1 }
        return counts.values.contains { $0 >= 3 }
    }

    /// Well past a coincidence: one action five times in the last ten.
    static func isStuckRepeating(_ records: [WorkingMemory.Record]) -> Bool {
        var counts: [String: Int] = [:]
        for record in records.suffix(10) { counts[record.fingerprint, default: 0] += 1 }
        return counts.values.contains { $0 >= 5 }
    }

    /// The same one, two or three actions three times over, even if each changed the
    /// screen. Open a dialog, close it, open it again goes nowhere.
    static func isCycling(_ records: [WorkingMemory.Record]) -> Bool {
        let prints = records.map(\.fingerprint)
        for period in 1...3 where prints.count >= period * 3 {
            let recent = Array(prints.suffix(period * 3))
            if (period..<recent.count).allSatisfy({ recent[$0] == recent[$0 - period] }) { return true }
        }
        return false
    }

    /// Every recent action met a screen not seen in that stretch, as when pressing Replace
    /// over and over changes one match at a time. Coming back to the same screen isn't this.
    static func isAdvancing(_ records: [WorkingMemory.Record], over count: Int = 4) -> Bool {
        let recent = records.suffix(count)
        guard recent.count == count, recent.allSatisfy(\.hadEffect) else { return false }
        return Set(recent.map(\.sceneFingerprint)).count == count
    }

    /// A B A B in the last four actions.
    static func isOscillating(_ records: [WorkingMemory.Record]) -> Bool {
        let last = records.suffix(4).map(\.fingerprint)
        guard last.count == 4 else { return false }
        return last[0] == last[2] && last[1] == last[3] && last[0] != last[1]
    }

    /// Exactly the action that just did nothing on exactly this screen. It would do
    /// nothing again, or worse, do something twice.
    public static func isPointlessRepeat(fingerprint: String, isWait: Bool, records: [WorkingMemory.Record], sceneFingerprint: String) -> Bool {
        if isWait { return false }
        return records.suffix(3).contains {
            $0.fingerprint == fingerprint && !$0.hadEffect && $0.sceneFingerprint == sceneFingerprint
        }
    }
}
