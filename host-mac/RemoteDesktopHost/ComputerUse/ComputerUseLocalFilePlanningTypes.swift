import Foundation

/// Shared value type for the existing host-bounded file proposal path.
/// Candidate IDs remain proposals; active host code revalidates them.
enum ComputerUseLocalFileOperation: Sendable, Equatable {
    case listFiles(query: ComputerUseLocalFileCatalog.Query, cursor: String?)
    case selectFile(candidateID: String)
    case selectLocalFile(candidateID: String, triggerControlID: String)
    case askFile(question: String, candidateIDs: [String])
}

/// Existing bounded local-file catalog context used by legacy native desktop jobs.
struct ComputerUseLocalFileContext: Sendable, Equatable {
    enum InventoryState: String, Sendable, Equatable { case notQueried, available }
    let inventoryState: InventoryState
    let query: ComputerUseLocalFileCatalog.Query
    let page: ComputerUseLocalFileCatalog.Page
    let selectedCandidate: ComputerUseLocalFileCatalog.Candidate?
    let nameFilterWasBroadened: Bool

    init(query: ComputerUseLocalFileCatalog.Query, page: ComputerUseLocalFileCatalog.Page,
         selectedCandidate: ComputerUseLocalFileCatalog.Candidate? = nil,
         nameFilterWasBroadened: Bool = false,
         inventoryState: InventoryState = .available) {
        self.inventoryState = inventoryState
        self.query = query; self.page = page; self.selectedCandidate = selectedCandidate
        self.nameFilterWasBroadened = nameFilterWasBroadened
    }
}
