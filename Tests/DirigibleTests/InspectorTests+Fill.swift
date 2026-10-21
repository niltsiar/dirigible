import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The inspector panes fill the inspector width (run ui-polish-chrome criteria C18, C23, C28,
/// C33). The test process shows the string keys, so a cut Spanish label is a screenshot check.
extension InspectorTests {
    /// The window of `package()` at 1180 pt with the inspector at `width` on `tab`; on the Clip
    /// tab, the Marks are over clip A.
    func pane(_ name: String, width: Double, tab: InspectorTab) async throws -> (SessionWindow, NSWindow) {
        let (model, _, window, _) = try await open(try await package(name))
        window.setContentSize(NSSize(width: 1180, height: 700))
        await until("the window takes 1180 pt") { window.contentLayoutRect.width == 1180 }
        model.inspectorWidth = InspectorWidth(width)
        model.inspectorTab = tab
        if tab == .clip { model.timeline.marks = overA }
        await until(limit: .seconds(10), "the pane shows its fields at \(width) pt") {
            paneControls(NSTextField.self, window, width: width).filter(\.isEditable).count >= (tab == .clip ? 3 : 8)
        }
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        return (model, window)
    }

    /// The views of `type` in the inspector of `width` pt.
    func paneControls<V: NSView>(_ type: V.Type, _ window: NSWindow, width: Double) -> [V] {
        window.contentView?.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [V] { ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return (window.contentView.map(all) ?? []).filter { inWindow($0).minX >= 1180 - width }
    }

    func inWindow(_ view: NSView) -> NSRect { view.convert(view.alignmentRect(forFrame: view.bounds), to: nil) }

    /// C33, C18: at 240, 270, and 400 pt, the picker, each Episode field, and the Notes editor end
    /// at the pane trailing edge (12 pt padding), and the Details fields share one leading edge.
    /// The four Clip fields stay 72 pt.
    @Test func eachPaneFillsTheWidth() async throws {
        for width in [240.0, 270, 400] {
            for tab in [InspectorTab.clip, .episode] {
                let (model, window) = try await pane("fill\(Int(width))\(tab)", width: width, tab: tab)
                let at = "\(tab) at \(Int(width)) pt"
                let picker = try #require(paneControls(NSSegmentedControl.self, window, width: width).first, "\(at)")
                // The test process shows the keys: the picker needs 265 pt for its two keys, so a
                // narrower pane goes past the window edge by the difference (the divider, 1 pt,
                // and the padding, 2 x 12 pt). The app labels fit 240 pt (screenshot M8).
                let over = max(0, Double(inWindow(picker).width) + 25 - width)
                let edge = 1180.0 - 12 + over
                #expect(abs(inWindow(picker).maxX - edge) <= 1, "\(at): picker \(inWindow(picker))")
                let fields = paneControls(NSTextField.self, window, width: width).filter(\.isEditable).map(inWindow)
                if tab == .clip {
                    #expect(fields.count == 4 && fields.allSatisfy { abs($0.width - 72) <= 0.5 }, "\(at): \(fields)")
                } else {
                    for field in fields {
                        #expect(abs(field.maxX - edge) <= 1, "\(at): field \(field)")
                    }
                    let details = fields.sorted { $0.minY > $1.minY }.prefix(8)
                    let starts = details.map(\.minX)
                    #expect((starts.max() ?? 0) - (starts.min() ?? 0) <= 0.5, "\(at): leading edges \(starts)")
                    let notes = try #require(
                        paneControls(NSTextView.self, window, width: width).first { !$0.isFieldEditor }?
                            .enclosingScrollView, "\(at): no Notes editor")
                    #expect(abs(inWindow(notes).maxX - edge) <= 1, "\(at): Notes \(inWindow(notes))")
                }
                await model.close()
            }
        }
    }

    /// C23: Choose… and Remove beside the artwork well have one width.
    @Test func theArtworkButtonsHaveOneWidth() async throws {
        let (model, window) = try await pane("artwork", width: 270, tab: .episode)
        // The two top buttons of the pane: the AppKit buttons do not carry the SwiftUI identifiers.
        let buttons = paneControls(NSButton.self, window, width: 270).filter { !($0 is NSPopUpButton) }
            .map(inWindow).sorted { $0.maxY > $1.maxY }
        try #require(buttons.count >= 2, "\(buttons)")
        let (a, b) = (buttons[0], buttons[1])
        #expect(abs(a.width - b.width) <= 0.5, "Choose \(a), Remove \(b)")
        #expect(a.height >= 15, "\(a)")
        await model.close()
    }

    /// C28: every editable field of both tabs has the small control size; the picker is regular.
    @Test func bothTabsUseOneControlSize() async throws {
        for tab in [InspectorTab.clip, .episode] {
            let (model, window) = try await pane("size\(tab)", width: 270, tab: tab)
            let fields = paneControls(NSTextField.self, window, width: 270).filter(\.isEditable)
            #expect(fields.allSatisfy { $0.controlSize == .small }, "\(tab): \(fields.map(\.controlSize.rawValue))")
            let picker = try #require(paneControls(NSSegmentedControl.self, window, width: 270).first)
            #expect(picker.controlSize == .regular, "\(tab): picker \(picker.controlSize.rawValue)")
            await model.close()
        }
    }
}
