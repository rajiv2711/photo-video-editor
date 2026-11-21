import Foundation

// The history of an edit (Undo, Redo and the History panel), as in Lightroom: every change made by
// touch or by name is a step holding the whole edit, so going back is putting an earlier state back.
// A slider dragged or a shape dragged is one step, however many times it moved (`key`). How the user
// looks at the photo (the View panel, the Include switches) and what is selected are not steps of
// their own: undo leaves the view as it is and puts the selection back with the edit.

/// The steps of one photo's edit, oldest first: step 0 is the photo as opened.
public struct EditHistory: Equatable {
    /// One state of the edit and what made it ("exposure 0.5", "Mask 1: brush stroke", …).
    public struct Step: Equatable {
        public let label: String
        public fileprivate(set) var state: EditState
        /// Records with the same key merge into this step while it is the newest (one drag).
        fileprivate var key: String?
    }

    public private(set) var steps: [Step]
    /// The step the edit is at now (lower after an undo).
    public private(set) var position: Int
    private let registry: ControlRegistry

    /// At most this many steps are kept (the first, the photo as opened, always is).
    public static let limit = 300

    public init(_ start: EditState = EditState(), registry: ControlRegistry, label: String = "Opened") {
        self.registry = registry
        steps = [Step(label: label, state: start, key: nil)]
        position = 0
    }

    public static func == (a: EditHistory, b: EditHistory) -> Bool {
        a.steps == b.steps && a.position == b.position
    }

    /// The step the edit is at now.
    public var current: Step { steps[position] }
    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < steps.count - 1 }

    /// Records the edit after a change: a new step after the current one (any steps undone before are
    /// dropped). Nothing new when only the view or the selection changed: the current step then
    /// remembers them. `key`: a record with the newest step's key replaces that step (a drag).
    public mutating func record(_ state: EditState, label: String, key: String? = nil) {
        if edit(state) == edit(steps[position].state) {
            steps[position].state = state
            return
        }
        if let key, key == steps[position].key, position > 0, position == steps.count - 1 {
            steps[position] = Step(label: label, state: state, key: key)
            return
        }
        steps.removeSubrange((position + 1)...)
        steps.append(Step(label: label, state: state, key: key))
        if steps.count > Self.limit { steps.remove(at: 1) }
        position = steps.count - 1
    }

    /// Puts `state` in the current step as it is (bookkeeping that belongs to the change just made).
    public mutating func amend(_ state: EditState) {
        steps[position].state = state
    }

    /// The next record starts a new step even with the same key (a drag ended).
    public mutating func seal() {
        steps[position].key = nil
    }

    /// Goes back `count` steps (as far as there are): the labels of the steps undone, newest first.
    @discardableResult
    public mutating func undo(_ count: Int = 1) -> [String] {
        let n = Swift.min(Swift.max(1, count), position)
        let undone = steps[(position - n + 1)...position].map(\.label).reversed()
        position -= n
        steps[position].key = nil
        return Array(undone)
    }

    /// Goes forward `count` steps again: the labels of the steps redone, oldest first.
    @discardableResult
    public mutating func redo(_ count: Int = 1) -> [String] {
        let n = Swift.min(Swift.max(1, count), steps.count - 1 - position)
        let redone = steps[(position + 1)..<(position + 1 + n)].map(\.label)
        position += n
        return Array(redone)
    }

    /// Goes to step `index` (0 = the photo as opened); false when there is no such step.
    @discardableResult
    public mutating func jump(to index: Int) -> Bool {
        guard steps.indices.contains(index) else { return false }
        position = index
        steps[position].key = nil
        return true
    }

    /// The current step's edit with `live`'s view and Include switches (how the user looks and works stays).
    public func restored(keeping live: EditState) -> EditState {
        var out = steps[position].state
        for control in registry.controls where Workflow.isSetting(control) {
            out.values[control.id] = live.values[control.id]
        }
        return out
    }

    /// What counts as a change: the edit without the view, the Include switches and the selection.
    private func edit(_ state: EditState) -> EditState {
        var out = state.normalized(registry)
        for control in registry.controls where Workflow.isSetting(control) { out.values[control.id] = nil }
        for id in Presets.selectors { out.values[id] = nil }
        for i in out.masks.indices { out.masks[i].selectedComponent = 0 }
        return out
    }
}
