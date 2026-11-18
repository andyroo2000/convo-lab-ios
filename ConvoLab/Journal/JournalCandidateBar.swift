import UIKit

/// A real input accessory, so UIKit reserves its height above the keyboard.
final class JournalCandidateBar: UIInputView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let collection: UICollectionView
    private var choices: [String] = []
    private var context = ""
    var choose: ((Int) -> Void)?
    var dismissKeyboard: (() -> Void)?

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.register(JournalCandidateCell.self, forCellWithReuseIdentifier: "candidate")
        collection.accessibilityIdentifier = "JournalCandidates"
        let hide = UIButton(type: .system)
        hide.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        hide.tintColor = .label
        hide.accessibilityLabel = "Hide keyboard"
        hide.addAction(UIAction { [weak self] _ in self?.dismissKeyboard?() }, for: .touchUpInside)
        for view in [collection, hide] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            collection.topAnchor.constraint(equalTo: topAnchor), collection.bottomAnchor.constraint(equalTo: bottomAnchor),
            collection.trailingAnchor.constraint(equalTo: hide.leadingAnchor),
            hide.trailingAnchor.constraint(equalTo: trailingAnchor), hide.widthAnchor.constraint(equalToConstant: 44),
            hide.topAnchor.constraint(equalTo: topAnchor), hide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func update(_ choices: [String], context: String) {
        if self.context != context {
            self.context = context
            collection.setContentOffset(.zero, animated: false)
        }
        guard self.choices != choices else { return }
        self.choices = choices
        collection.reloadData()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { choices.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "candidate", for: indexPath) as! JournalCandidateCell
        cell.label.text = choices[indexPath.item]
        cell.accessibilityLabel = choices[indexPath.item]
        cell.accessibilityHint = "Commit this spelling"
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { choose?(indexPath.item) }
    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let size = (choices[indexPath.item] as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        return CGSize(width: max(48, ceil(size.width) + 28), height: 48)
    }
}

private final class JournalCandidateCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20)
        label.textAlignment = .center
        label.frame = contentView.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { nil }
}
