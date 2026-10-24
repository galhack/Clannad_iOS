import UIKit

struct PlayerStorySelection: Decodable, Equatable {
    let generation: UInt64
    let choices: [String]
    let canCancel: Bool
}

/// Explicit story decisions. The full-screen control also keeps background
/// taps from choosing a branch or advancing the scene below the panel.
final class PlayerChoicePanel: UIControl {
    var onSelect: ((Int) -> Void)?

    init(choices: [String], canCancel: Bool) {
        super.init(frame: .zero)
        accessibilityIdentifier = "player.choices"
        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        #if os(iOS) && !targetEnvironment(macCatalyst)
        let cardWidth: CGFloat = 420
        let padding: CGFloat = 14
        let spacing: CGFloat = 8
        #else
        let cardWidth: CGFloat = 640
        let padding: CGFloat = 20
        let spacing: CGFloat = 12
        #endif
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .secondarySystemBackground
        scroll.layer.cornerRadius = 18
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let title = UILabel()
        title.text = "请选择剧情分支"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        title.accessibilityTraits = .header
        stack.addArrangedSubview(title)
        let hint = UILabel()
        hint.text = "快进已暂停"
        hint.font = .preferredFont(forTextStyle: .subheadline)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(hint)

        for (index, text) in choices.enumerated() {
            addButton(text, index: index, id: "player.choice.\(index)", to: stack)
        }
        if canCancel {
            addButton("取消", index: -1, id: "player.choice.cancel", to: stack)
        }
        NSLayoutConstraint.activate([
            scroll.centerXAnchor.constraint(equalTo: centerXAnchor),
            scroll.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.widthAnchor.constraint(lessThanOrEqualToConstant: cardWidth),
            scroll.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor, multiplier: 0.65),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -padding),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -padding * 2),
        ])
        let width = scroll.widthAnchor.constraint(equalToConstant: cardWidth)
        width.priority = .defaultHigh
        width.isActive = true
        let contentHeight = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: padding * 2)
        contentHeight.priority = .defaultHigh
        contentHeight.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addButton(_ text: String, index: Int, id: String, to stack: UIStackView) {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = text
        configuration.titleAlignment = .center
        configuration.titleLineBreakMode = .byWordWrapping
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let verticalInset: CGFloat = 10
        let minimumHeight: CGFloat = 44
        #else
        let verticalInset: CGFloat = 14
        let minimumHeight: CGFloat = 52
        #endif
        configuration.contentInsets = NSDirectionalEdgeInsets(top: verticalInset, leading: 16, bottom: verticalInset, trailing: 16)
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 0
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
        if let previous = stack.arrangedSubviews.last as? UIButton {
            stack.setCustomSpacing(32, after: previous)
        }
        stack.addArrangedSubview(button)
    }
}
