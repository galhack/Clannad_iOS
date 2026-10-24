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

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .secondarySystemBackground
        scroll.layer.cornerRadius = 18
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
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
            scroll.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            scroll.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor, multiplier: 0.65),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        let width = scroll.widthAnchor.constraint(equalToConstant: 640)
        width.priority = .defaultHigh
        width.isActive = true
        let contentHeight = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 40)
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
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 0
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
        if let previous = stack.arrangedSubviews.last as? UIButton {
            stack.setCustomSpacing(32, after: previous)
        }
        stack.addArrangedSubview(button)
    }
}
