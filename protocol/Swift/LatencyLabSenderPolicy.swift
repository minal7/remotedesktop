import Foundation

#if DEBUG
enum LatencyLabSenderPolicy {
    struct Path: Equatable {
        let id: String
        let localType: String
        let remoteType: String
        var isLAN: Bool { localType == "host" && remoteType == "host" }
        var minimumBitrate: Int { isLAN ? 2_500_000 : 0 }
        var startingBitrate: Int { isLAN ? 10_000_000 : 4_000_000 }
        let maximumBitrate = 30_000_000
    }

    /// A nominated-but-not-selected pair must never reset the active estimate.
    static func selectedPath(in reports: [LatencyStatsReport]) -> Path? {
        let byID = Dictionary(reports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(reports.filter { $0.type == "transport" }
            .compactMap { $0.values["selectedCandidatePairId"] as? String })
        guard ids.count == 1, let id = ids.first, let pair = byID[id],
              pair.type == "candidate-pair", pair.values["state"] as? String == "succeeded",
              let localID = pair.values["localCandidateId"] as? String,
              let remoteID = pair.values["remoteCandidateId"] as? String,
              let local = byID[localID]?.values["candidateType"] as? String,
              let remote = byID[remoteID]?.values["candidateType"] as? String,
              ["host", "srflx", "prflx", "relay"].contains(local),
              ["host", "srflx", "prflx", "relay"].contains(remote) else { return nil }
        return Path(id: id, localType: local, remoteType: remote)
    }
}
#endif
