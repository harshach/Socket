import Foundation

public final class PageResidencyController {
    public let maxLivePages: Int
    private var livePageIDs: [UUID] = []

    public init(maxLivePages: Int = 6) {
        self.maxLivePages = max(2, maxLivePages)
    }

    public func touch(_ pageID: UUID?) {
        guard let pageID else {
            return
        }

        livePageIDs.removeAll { $0 == pageID }
        livePageIDs.append(pageID)
    }

    @discardableResult
    public func reconcile(protectedIDs: Set<UUID>) -> [UUID] {
        for pageID in protectedIDs where !livePageIDs.contains(pageID) {
            livePageIDs.append(pageID)
        }

        let minimumLiveCount = max(maxLivePages, protectedIDs.count)
        var evicted: [UUID] = []

        while livePageIDs.count > minimumLiveCount {
            guard let oldest = livePageIDs.first(where: { !protectedIDs.contains($0) }),
                  let index = livePageIDs.firstIndex(of: oldest) else {
                break
            }

            evicted.append(oldest)
            livePageIDs.remove(at: index)
        }

        return evicted
    }

    public func currentlyLivePageIDs() -> [UUID] {
        livePageIDs
    }
}
