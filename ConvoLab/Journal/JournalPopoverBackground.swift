import UIKit

final class JournalPopoverBackground: UIPopoverBackgroundView {
    private var offset: CGFloat = 0
    private var direction: UIPopoverArrowDirection = .up
    private let bubble = CAShapeLayer()

    override var arrowOffset: CGFloat {
        get { offset }
        set { offset = newValue; setNeedsLayout() }
    }
    override var arrowDirection: UIPopoverArrowDirection {
        get { direction }
        set { direction = newValue; setNeedsLayout() }
    }
    override class func arrowBase() -> CGFloat { 24 }
    override class func arrowHeight() -> CGFloat { 12 }
    override class func contentViewInsets() -> UIEdgeInsets { .zero }
    override class var wantsDefaultContentAppearance: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(bubble)
        bubble.fillColor = UIColor.white.cgColor
        bubble.strokeColor = UIColor(red: 0.72, green: 0.70, blue: 0.68, alpha: 0.65).cgColor
        bubble.lineWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = direction == .up
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
            .inset(by: UIEdgeInsets(top: top ? 12 : 0, left: 0, bottom: top ? 0 : 12, right: 0))
        let path = UIBezierPath(roundedRect: body, cornerRadius: 24)
        // Place the arrow on the shared silhouette without an interior border.
        let x = min(body.maxX - 36, max(body.minX + 36, bounds.midX + offset))
        let y = top ? body.minY : body.maxY
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: x - 12, y: y))
        arrow.addLine(to: CGPoint(x: x, y: y + (top ? -12 : 12)))
        arrow.addLine(to: CGPoint(x: x + 12, y: y))
        arrow.close()
        let silhouette = path.cgPath.union(arrow.cgPath)
        bubble.path = silhouette
        layer.shadowPath = silhouette
    }
}
