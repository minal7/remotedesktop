import Combine
import Foundation

/// Display state only. Neither status text nor a notification grants control,
/// establishes a document, or proves that sign-in succeeded.
@MainActor
final class ComputerUseBrowserPresentation {
    typealias Controls = ComputerUseBrowserTaskControls
    typealias Handler = (Controls, Controls.Action) -> Void
    enum TaskState: Equatable { case ready, active, stopped, closed }
    enum PageActivity: String {
        case ready = "Ready"
        case checkingRequest = "Checking the page for the new request"
        case returnedEmpty = "Control returned — ready to open the first page"
        case returned = "Control returned — checking the current page"
        case checking = "Checking the current page"
        case opening = "Opening page…"
        case changed = "Page changed"
        case interrupted = "Page request interrupted"
        case signInClosed = "Sign-in window closed — choose Let AI continue when you are ready"
        case readyForTask = "Page ready — checking the current task"
        case readyForHandback = "Page ready — choose Let AI continue when you are finished"
        case opened = "Page opened"

        var displayDetail: String {
            switch self {
            case .returnedEmpty: return "No page opened"
            case .checkingRequest, .returned, .checking: return "Checking the current page"
            case .readyForTask, .readyForHandback: return "Page opened"
            case .signInClosed: return "Sign-in window closed"
            default: return rawValue
            }
        }
    }
    enum Issue {
        case navigation(ComputerUseBrowserError), sourceBlocked, parentProcessStopped, signInProcessStopped
        var message: String {
            switch self {
            case .navigation(let error): return error.localizedDescription
            case .sourceBlocked: return "Blocked a page outside this task's allowed sources."
            case .parentProcessStopped: return "Browser process stopped"
            case .signInProcessStopped: return "The sign-in window stopped. Check the main page before continuing."
            }
        }
    }
    struct State {
        var task: TaskState = .ready
        var taskID: String?
        var site = ComputerUseBrowserSite.displayName(for: nil)
        var page: PageActivity = .ready
        var issue: Issue?
        var controls: Controls?
        var handler: Handler?
        var signInSite: String?
        var signInStatus = ComputerUseSignInPageStatus()
        var signInDetail: String { signInStatus.detail }

        var taskDetail: String {
            switch task {
            case .ready: return "Ready for a task"
            case .stopped: return "Stopped"
            case .closed: return "Closed"
            case .active:
                guard controls?.taskID == taskID else { return "Task active" }
                switch controls?.phase {
                case .working: return "AI is working"
                case .paused: return "You have control"
                case .awaitingApproval: return "Waiting for approval"
                case nil: return "Task active"
                }
            }
        }
        // Compatibility projection for diagnostics. The view shows task,
        // page activity and issue separately instead of choosing one caption.
        var detail: String {
            if task == .stopped || task == .closed { return taskDetail }
            return issue?.message ?? page.rawValue
        }
    }
    enum Update {
        case claim(String), retire(TaskState, clearSite: Bool)
        case site(String), page(PageActivity, recovered: Bool = false), issue(Issue)
        case controls(Controls?, Handler)
        case signInSite(String?), signInStatus(ComputerUseSignInPageStatus)
    }
    private enum Field: Hashable { case task, site, page, issue, controls, signInSite, signInDetail }
    let objectWillChange = ObservableObjectPublisher()
    private(set) var state = State()
    private let siteSubject = CurrentValueSubject<String, Never>(State().site)
    private let detailSubject = CurrentValueSubject<String, Never>(State().detail)
    private let signInSiteSubject = CurrentValueSubject<String?, Never>(nil)
    private let signInDetailSubject = CurrentValueSubject<String, Never>(State().signInDetail)
    private let controlsSubject = CurrentValueSubject<Controls?, Never>(nil)
    var siteChanges: AnyPublisher<String, Never> { siteSubject.eraseToAnyPublisher() }
    var detailChanges: AnyPublisher<String, Never> { detailSubject.eraseToAnyPublisher() }
    var signInSiteChanges: AnyPublisher<String?, Never> { signInSiteSubject.eraseToAnyPublisher() }
    var signInDetailChanges: AnyPublisher<String, Never> { signInDetailSubject.eraseToAnyPublisher() }
    var controlsChanges: AnyPublisher<Controls?, Never> { controlsSubject.eraseToAnyPublisher() }
    private var revisions: [Field: UUID] = [:]
    private var notifyingWillChange = false
    private var delivering = false
    private var notifications: [() -> Void] = []

    /// Recheck after will-change, then commit a delta to the *current* state.
    /// Nested changes to another field survive; a newer write to this field or
    /// a different native/task owner retires the older write before assignment.
    func update(_ update: Update, isCurrent: @escaping () -> Bool = { true }) {
        let fields: Set<Field>
        switch update {
        case .claim, .retire: fields = [.task, .site, .page, .issue, .signInSite, .signInDetail]
        case .site: fields = [.site]
        case .page(_, let recovered): fields = recovered ? [.page, .issue] : [.page]
        case .issue: fields = [.issue]
        case .controls: fields = [.controls]
        case .signInSite: fields = [.signInSite]
        case .signInStatus: fields = [.signInDetail]
        }
        let revision = UUID()
        for field in fields { revisions[field] = revision }
        if !notifyingWillChange {
            notifyingWillChange = true
            objectWillChange.send()
            notifyingWillChange = false
        }
        guard isCurrent() else { return }
        func current(_ field: Field) -> Bool { revisions[field] == revision }
        guard fields.contains(where: current) else { return }
        let previous = state
        switch update {
        case .claim(let taskID):
            if current(.task) { state.task = .active; state.taskID = taskID }
            if current(.page) { state.page = .ready }
            if current(.issue) { state.issue = nil }
            if current(.signInSite) { state.signInSite = nil }
            if current(.signInDetail) { state.signInStatus = .init() }
        case .retire(let task, let clearSite):
            if current(.task) { state.task = task; state.taskID = nil }
            if current(.signInSite) { state.signInSite = nil }
            if clearSite && current(.site) { state.site = State().site }
        case .site(let value): if current(.site) { state.site = value }
        case .page(let value, let recovered):
            if current(.page) { state.page = value }
            if recovered && current(.issue) { state.issue = nil }
        case .issue(let value): if current(.issue) { state.issue = value }
        case .controls(let value, let handler):
            if current(.controls) { state.controls = value; state.handler = handler }
        case .signInSite(let value): if current(.signInSite) { state.signInSite = value }
        case .signInStatus(let value): if current(.signInDetail) { state.signInStatus = value }
        }
        // Queue refreshes, not retained snapshots. A preceding field's
        // subscriber may already have installed another owner. The next field
        // then publishes that owner's current value, never the abandoned one.
        switch update {
        case .claim:
            if previous.signInSite != state.signInSite { notifications.append { self.signInSiteSubject.send(self.state.signInSite) } }
            if previous.signInDetail != state.signInDetail { notifications.append { self.signInDetailSubject.send(self.state.signInDetail) } }
            notifications.append { self.detailSubject.send(self.state.detail) }
        case .retire(_, let clearSite):
            if previous.signInSite != nil { notifications.append { self.signInSiteSubject.send(self.state.signInSite) } }
            if clearSite { notifications.append { self.siteSubject.send(self.state.site) } }
            notifications.append { self.detailSubject.send(self.state.detail) }
        case .site: notifications.append { self.siteSubject.send(self.state.site) }
        case .page, .issue: notifications.append { self.detailSubject.send(self.state.detail) }
        case .controls: notifications.append { self.controlsSubject.send(self.state.controls) }
        case .signInSite: notifications.append { self.signInSiteSubject.send(self.state.signInSite) }
        case .signInStatus: notifications.append { self.signInDetailSubject.send(self.state.signInDetail) }
        }
        // Nested value sends wait until every subscriber has received the
        // current event. Remaining refreshes use the latest committed state.
        guard !delivering else { return }
        delivering = true
        var index = 0
        while index < notifications.count {
            let notification = notifications[index]
            index += 1
            notification()
        }
        notifications.removeAll(keepingCapacity: true)
        delivering = false
    }
}
