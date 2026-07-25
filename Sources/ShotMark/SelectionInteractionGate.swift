import Foundation

final class SelectionInteractionGate {
    private var ownerID: ObjectIdentifier?

    @discardableResult
    func claim(_ owner: AnyObject) -> Bool {
        let candidateID = ObjectIdentifier(owner)
        if let ownerID {
            return ownerID == candidateID
        }
        ownerID = candidateID
        return true
    }

    func isOwner(_ owner: AnyObject) -> Bool {
        ownerID == ObjectIdentifier(owner)
    }

    func reset() {
        ownerID = nil
    }
}
