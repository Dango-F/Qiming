import AppKit

enum IconBadge: String { case none, paused, attention }

/// The same mother curves as design-assets/qiming-menubar-states.svg.
/// Small-size optical correction widens the inner negative space equally in all three modes.
@MainActor enum WingGeometry {
    static func paths(size: CGFloat) -> (outer: NSBezierPath, inner: NSBezierPath) {
        let scale = size / 22
        func point(_ x: CGFloat, _ y: CGFloat, inner: Bool = false) -> NSPoint {
            let shrink: CGFloat = size <= 22 ? 0.9 : 0.96
            let px = inner ? 10.9 + (x - 10.9) * shrink : x
            let py = inner ? 14.2 + (y - 14.2) * shrink + 0.12 : y
            return NSPoint(x: px * scale, y: (22 - py) * scale)
        }
        let outer = NSBezierPath()
        outer.move(to: point(3.5, 3))
        outer.curve(to: point(10.7, 10.1), controlPoint1: point(2.8, 8.1), controlPoint2: point(5.3, 9.5))
        outer.curve(to: point(16.1, 18), controlPoint1: point(15.7, 10.7), controlPoint2: point(18.5, 13.1))
        outer.curve(to: point(12.3, 7.4), controlPoint1: point(20, 13.6), controlPoint2: point(18, 8.5))
        outer.curve(to: point(3.5, 3), controlPoint1: point(7.8, 6.6), controlPoint2: point(4.8, 7.1))
        outer.close()
        let inner = NSBezierPath()
        inner.move(to: point(6, 11.1, inner: true))
        inner.curve(to: point(13.8, 12.2, inner: true), controlPoint1: point(8, 12, inner: true), controlPoint2: point(11.2, 10.6, inner: true))
        inner.curve(to: point(15.5, 17.3, inner: true), controlPoint1: point(15.4, 13.2, inner: true), controlPoint2: point(16.1, 15, inner: true))
        inner.curve(to: point(6, 11.1, inner: true), controlPoint1: point(13.7, 14.5, inner: true), controlPoint2: point(8.3, 15.9, inner: true))
        inner.close()
        for path in [outer, inner] {
            path.lineWidth = max(0.60, 0.68 * scale)
            path.lineJoinStyle = .round; path.lineCapStyle = .round
        }
        return (outer, inner)
    }
}
