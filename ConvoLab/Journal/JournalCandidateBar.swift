import UIKit

/// A real input accessory, so UIKit reserves its height above the keyboard.
final class JournalCandidateBar: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let collection: UICollectionView
    private var choices: [String] = []
    private var context = ""
    private let expand = UIButton(type: .system)
    private(set) var expanded = false
    private var highlighted = -1
    var sizeChanged: (() -> Void)?
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: expanded ? 216 : 48) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: intrinsicContentSize.height)
    }
    var choose: ((Int) -> Void)?
    var dismissKeyboard: (() -> Void)?

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48))
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .secondarySystemBackground
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.register(JournalCandidateCell.self, forCellWithReuseIdentifier: "candidate")
        collection.accessibilityIdentifier = "JournalCandidates"
        expand.tintColor = .label
        expand.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .touchUpInside)
        updateExpansionButton()
        for view in [collection, expand] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            collection.topAnchor.constraint(equalTo: topAnchor), collection.bottomAnchor.constraint(equalTo: bottomAnchor),
            collection.trailingAnchor.constraint(equalTo: expand.leadingAnchor),
            expand.trailingAnchor.constraint(equalTo: trailingAnchor), expand.widthAnchor.constraint(equalToConstant: 44),
            expand.topAnchor.constraint(equalTo: topAnchor), expand.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func toggleExpanded() {
        guard !choices.isEmpty else { dismissKeyboard?(); return }
        expanded.toggle()
        updateLayout()
    }

    private func updateExpansionButton() {
        expand.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
        expand.accessibilityLabel = choices.isEmpty ? "Hide keyboard" : (expanded ? "Collapse candidates" : "Show all candidates")
        expand.accessibilityIdentifier = "JournalExpandCandidates"
    }

    private func updateLayout() {
        (collection.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection = expanded ? .vertical : .horizontal
        collection.collectionViewLayout.invalidateLayout()
        collection.setContentOffset(.zero, animated: false)
        frame.size.height = intrinsicContentSize.height
        invalidateIntrinsicContentSize()
        updateExpansionButton()
        sizeChanged?()
    }

    func update(_ choices: [String], highlighted: Int = -1, context: String) {
        if self.context != context {
            self.context = context
            collection.setContentOffset(.zero, animated: false)
        }
        let changed = self.choices != choices || self.highlighted != highlighted
        self.choices = choices
        self.highlighted = highlighted
        if choices.isEmpty && expanded { expanded = false; updateLayout() }
        updateExpansionButton()
        guard changed else { return }
        collection.reloadData()
        if choices.indices.contains(highlighted) {
            collection.layoutIfNeeded()
            collection.scrollToItem(at: IndexPath(item: highlighted, section: 0), at: expanded ? .centeredVertically : .centeredHorizontally, animated: false)
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { choices.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "candidate", for: indexPath) as! JournalCandidateCell
        cell.label.text = choices[indexPath.item]
        cell.backgroundColor = indexPath.item == highlighted ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
        cell.accessibilityLabel = choices[indexPath.item]
        cell.accessibilityHint = "Commit this spelling"
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { choose?(indexPath.item) }
    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let size = (choices[indexPath.item] as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        return CGSize(width: min(max(48, ceil(size.width) + 28), max(48, collectionView.bounds.width)), height: 48)
    }
}

private final class JournalCandidateCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        label.frame = contentView.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { nil }
}
