import AppKit

final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Peaklight"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeContentView() -> NSView {
        let content = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = Self.appIcon()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 96),
            imageView.heightAnchor.constraint(equalToConstant: 96)
        ])

        let title = NSTextField(labelWithString: "Peaklight")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let tagline = NSTextField(labelWithString: "Raise the peak, keep the floor.")
        tagline.font = .systemFont(ofSize: 14)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center

        let version = NSTextField(labelWithAttributedString: Self.versionString())
        version.alignment = .center

        let okButton = NSButton(title: "OK", target: self, action: #selector(closeWindow))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(tagline)
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(22, after: version)
        stack.addArrangedSubview(okButton)

        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)
        ])

        return content
    }

    @objc private func closeWindow() {
        close()
    }

    private static func appIcon() -> NSImage {
        if let iconURL = Bundle.main.url(forResource: "Peaklight", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }

        return NSApp.applicationIconImage
    }

    private static func versionString() -> NSAttributedString {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = shortVersion ?? "1.0.0"
        let text = "Version \(version)"
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
        )

        if let range = text.range(of: version) {
            attributed.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: 14, weight: .bold),
                range: NSRange(range, in: text)
            )
        }

        return attributed
    }
}
