import Foundation
import CoreGraphics

/// Selection state independent of the board's layout and input device.
/// Supply card frames and drag points in the same coordinate space.
public struct BoardSelection: Equatable, Sendable {
    public private(set) var selectedIDs: Set<UUID>
    public private(set) var marquee: CGRect?

    private var origin: CGPoint?
    private var selectionBeforeDrag: Set<UUID> = []
    private var additiveSelection: Set<UUID> = []

    public init(selectedIDs: Set<UUID> = []) {
        self.selectedIDs = selectedIDs
    }

    public mutating func toggle(_ id: UUID) {
        end()
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    public mutating func selectAll(_ ids: [UUID]) {
        end()
        selectedIDs = Set(ids)
    }

    public mutating func clear() {
        end()
        selectedIDs.removeAll()
    }

    /// Call when the visible result set changes. End any in-progress gesture so
    /// stale card geometry cannot add notes from the previous view.
    public mutating func retainOnly(_ ids: Set<UUID>) {
        end()
        selectedIDs.formIntersection(ids)
    }

    public mutating func begin(at point: CGPoint, additive: Bool) {
        selectionBeforeDrag = selectedIDs
        additiveSelection = additive ? selectedIDs : []
        origin = point
        marquee = CGRect(origin: point, size: .zero)
        selectedIDs = additiveSelection
    }

    public mutating func update(to point: CGPoint, frames: [UUID: CGRect]) {
        guard let origin else { return }
        let rectangle = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                               width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        marquee = rectangle
        let hits = frames.compactMap { id, frame in
            // A newly started drag has zero area, but its starting card should
            // still be selected before the pointer moves further.
            frame.intersects(rectangle) || frame.contains(origin) ? id : nil
        }
        selectedIDs = additiveSelection.union(hits)
    }

    public mutating func end() {
        origin = nil
        marquee = nil
        selectionBeforeDrag.removeAll()
        additiveSelection.removeAll()
    }

    /// Escape/cancellation restores the selection from before this gesture.
    public mutating func cancel() {
        guard origin != nil else { return }
        selectedIDs = selectionBeforeDrag
        end()
    }
}
