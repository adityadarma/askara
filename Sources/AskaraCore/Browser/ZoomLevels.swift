/// Page zoom steps, similar to most browsers.
public enum ZoomLevels {
    public static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    public static func zoomIn(from current: Double) -> Double {
        steps.first { $0 > current + 0.001 } ?? steps.last!
    }

    public static func zoomOut(from current: Double) -> Double {
        steps.last { $0 < current - 0.001 } ?? steps.first!
    }

    public static func label(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }
}
