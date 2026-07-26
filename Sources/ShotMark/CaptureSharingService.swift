import AppKit
import Foundation

enum CaptureSharingService {
    static func items(
        for record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared,
        dragItemProvider: CaptureDragItemProvider = .shared
    ) throws -> [Any] {
        let url = try dragItemProvider.dragURL(for: record, store: store)
        return [url as NSURL]
    }
}

final class CaptureSharePresenter: NSObject, NSSharingServicePickerDelegate {
    var onVisibilityChanged: ((Bool) -> Void)?

    private var picker: NSSharingServicePicker?

    func present(
        items: [Any],
        relativeTo rect: CGRect,
        of view: NSView,
        preferredEdge: NSRectEdge = .minY
    ) {
        precondition(Thread.isMainThread)
        picker?.close()

        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        onVisibilityChanged?(true)
        picker.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    func close() {
        precondition(Thread.isMainThread)
        picker?.close()
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose sharingService: NSSharingService?
    ) {
        precondition(Thread.isMainThread)
        guard picker === sharingServicePicker else { return }
        picker = nil
        onVisibilityChanged?(false)
    }
}
