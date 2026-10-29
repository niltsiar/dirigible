import DirigibleCore
import Foundation

extension TimelineGesture {
    /// The rectangle of a marquee drag from the press to the pointer in document points; nil in any
    /// other state.
    public var marquee: Rect? {
        guard case .marqueeing(let press, let x, let y) = state else { return nil }
        return Rect(x: min(press.x, x), y: min(press.y, y), width: abs(x - press.x), height: abs(y - press.y))
    }

    /// A marquee drag event: the clips that the rectangle holds whole in time, on each lane that it
    /// touches, become the selection. It never snaps and never changes the session.
    mutating func marqueeDrag(_ press: Press, _ x: Double, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        state = .marqueeing(press, x: x, y: y)
        let geometry = context.geometry
        let held = Marks.drag(
            from: press.frame, to: geometry.frame(at: x), lanes: (geometry.lane(at: press.y), geometry.lane(at: y)),
            in: context.session)
        return [
            .selection(ClipSet(Set(held.heldClips(in: context.session).map(\.clip.id))).map { .clips($0) } ?? .none)
        ]
    }
}
