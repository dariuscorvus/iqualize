import AppKit

/// Hosts the preset sidebar + EQ content as native split view panes, giving the window a
/// Finder/Mail-style collapsible sidebar with a toolbar-tracking divider under the unified
/// toolbar. `NSSplitViewController.toggleSidebar(_:)` (inherited, no override needed) finds
/// `sidebarItem` automatically because it's constructed via `sidebarWithViewController:`.
@available(macOS 14.2, *)
@MainActor
final class DreamSplitViewController: NSSplitViewController {
    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem

    init(sidebarView: NSView, contentView: NSView) {
        let sidebarVC = NSViewController()
        sidebarVC.view = sidebarView
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        sidebarItem.isCollapsed = true

        let contentVC = NSViewController()
        contentVC.view = contentView
        contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 820

        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        splitView.autosaveName = "DreamSplitView"
        splitView.identifier = NSUserInterfaceItemIdentifier("DreamSplitView")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
