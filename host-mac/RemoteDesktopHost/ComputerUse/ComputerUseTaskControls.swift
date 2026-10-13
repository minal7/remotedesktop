import Foundation

/// A display projection for the current local task controls. Button authority
/// is scoped to the exact rendered task and owner presentation.
struct ComputerUseTaskControls: Equatable {
    enum Phase: Equatable { case working, paused, awaitingApproval }
    enum Action { case takeControl, resume, stop }
    let taskID: String
    let scopeID: UUID
    let presentationID: UUID
    let phase: Phase
    let canResume: Bool
    /// Stable through Pause/Resume; changes with peer, session, authorization,
    /// transport or task ownership.
    let ownerID: UUID

    init(taskID: String, scopeID: UUID, presentationID: UUID, phase: Phase,
         canResume: Bool, ownerID: UUID? = nil) {
        self.taskID = taskID
        self.scopeID = scopeID
        self.presentationID = presentationID
        self.phase = phase
        self.canResume = canResume
        self.ownerID = ownerID ?? scopeID
    }
}
