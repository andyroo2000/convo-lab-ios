import UIKit

/// Keeps UIKit's anchored presentation and dismissal, with ConvoLab's compact surface.
final class JournalPopoverBackground: UIPopoverBackgroundView {
    private let bodyLayer = CALayer()
    private let arrowLayer = CAShapeLayer()
    private var offset: CGFloat = 0
    private var direction: UIPopoverArrowDirection = .up

    override var arrowOffset: CGFloat {
        get { offset }
        set { offset = newValue; setNeedsLayout() }
    }
    override var arrowDirection: UIPopoverArrowDirection {
        get { direction }
        set { direction = newValue; setNeedsLayout() }
    }
    override class func arrowBase() -> CGFloat { 16 }
    override class func arrowHeight() -> CGFloat { 8 }
    override class func contentViewInsets() -> UIEdgeInsets { .zero }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(bodyLayer)
        layer.addSublayer(arrowLayer)
        bodyLayer.cornerRadius = 14
        bodyLayer.borderWidth = 1
        arrowLayer.lineWidth = 1
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: JournalPopoverBackground, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only vertical arrow directions are permitted by JournalHighlights.
        let pointsUp = direction == .up
        let body = CGRect(x: 0, y: pointsUp ? 8 : 0, width: bounds.width, height: bounds.height - 8)
        let center = min(max(bounds.midX + offset, 24), bounds.width - 24)
        let base = pointsUp ? body.minY : body.maxY
        let tip = pointsUp ? bounds.minY : bounds.maxY
        let fill = JournalPopoverStyle.surface.resolvedColor(with: traitCollection).cgColor
        let border = JournalPopoverStyle.line.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
        bodyLayer.frame = body
        bodyLayer.backgroundColor = fill
        bodyLayer.borderColor = border
        arrowLayer.fillColor = fill
        arrowLayer.strokeColor = border
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center - 8, y: base))
        path.addLine(to: CGPoint(x: center, y: tip))
        path.addLine(to: CGPoint(x: center + 8, y: base))
        arrowLayer.path = path.cgPath
        CATransaction.commit()
    }
}
