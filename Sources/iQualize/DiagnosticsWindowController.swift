import AppKit

@available(macOS 14.2, *)
@MainActor
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    typealias SnapshotProvider = @MainActor () -> RuntimeDiagnosticsSnapshot

    private let snapshotProvider: SnapshotProvider
    private var valueLabels: [String: NSTextField] = [:]
    private var diagnosticReport = ""

    convenience init(audioEngine: AudioEngine) {
        self.init(snapshotProvider: {
            audioEngine.runtimeDiagnosticsSnapshot()
        })
    }

    init(snapshotProvider: @escaping SnapshotProvider) {
        self.snapshotProvider = snapshotProvider

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 0),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Diagnostics"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        let contentView = buildContent()
        window.contentView = contentView
        refresh()

        let fitting = contentView.fittingSize
        window.setContentSize(NSSize(width: max(fitting.width, 560), height: fitting.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let presentation = RuntimeDiagnosticsPresentation.make(snapshot: snapshotProvider())
        diagnosticReport = presentation.report
        for row in presentation.rows {
            valueLabels[row.label]?.stringValue = row.value
        }
    }

    private func buildContent() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Runtime Diagnostics")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        mainStack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Read-only audio runtime telemetry. Refresh rereads the current snapshot only.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        mainStack.addArrangedSubview(subtitle)

        let grid = NSGridView(views: RuntimeDiagnosticsPresentation.make(snapshot: .init(status: .initial)).rows.map { row in
            let label = NSTextField(labelWithString: row.label + ":")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)

            let value = NSTextField(labelWithString: RuntimeDiagnosticsPresentation.unavailable)
            value.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            value.textColor = .labelColor
            value.lineBreakMode = .byWordWrapping
            value.maximumNumberOfLines = 0
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
            valueLabels[row.label] = value

            return [label, value]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = NSGridCell.Placement.trailing
        grid.column(at: 1).xPlacement = NSGridCell.Placement.leading
        grid.column(at: 1).width = 360
        mainStack.addArrangedSubview(grid)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshButtonPressed(_:)))
        refreshButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(refreshButton)

        let copyButton = NSButton(title: "Copy Diagnostic Report", target: self, action: #selector(copyDiagnosticReport(_:)))
        copyButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(copyButton)

        mainStack.addArrangedSubview(buttonRow)

        let container = NSView()
        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func refreshButtonPressed(_ sender: NSButton) {
        refresh()
    }

    @objc private func copyDiagnosticReport(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
    }
}
