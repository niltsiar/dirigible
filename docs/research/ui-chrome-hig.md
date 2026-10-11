# The window chrome and the Apple HIG

Date: 2026-10-11

This file collects the HIG and SwiftUI rules for the buttons of the empty session, the Change… and Create buttons of the start window, the inspector width, the split view divider, the banner buttons, and the toolbar toggles. It gives facts, and it marks each inference. The decisions are in `docs/decisions/0023-ui-shell.md`.

Method: we fetched the HIG pages as DocC JSON and rendered them to text. All quotes are verbatim.

## Buttons

- Style for the likely action: "use a button that has a prominent visual style for the most likely action in a view." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Limit: "Keep the number of prominent buttons to one or two per view." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Size in a set: "Use style — not size — to visually distinguish the preferred choice among multiple options." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Same size means a set: "When you use buttons of the same size to offer two or more options, you signal that the options form a coherent set of choices." and "placing two buttons of different sizes near each other can make the interface look confusing and inconsistent." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Primary role: "Assign the primary role to the button people are most likely to choose." It responds to Return, and a sheet or alert "can automatically close when people press Return." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- No destructive default: "Don’t assign the primary role to a button that performs a destructive action, even if that action is the most likely choice." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- macOS push button: "The standard button type in macOS is known as a push button." "Push buttons can act as the default button in a view and you can tint them." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Ellipsis: "Append a trailing ellipsis to the title when a push button opens another window, view, or app." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Image buttons: "Use an image button in a view, not in the window frame." "Include about 10 pixels of padding between the edges of the image and the button edges." "In general, avoid including a system-provided border in an image button". "If you need to include a label, position it below the image button." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Equal heights in a stack: this rule is in the watchOS section only: "Use the same height for vertical stacks of one- and two-line text buttons." [https://developer.apple.com/design/human-interface-guidelines/buttons]
- Stack shape: this rule is in the visionOS section only: "prefer the rounded-rectangle shape in a vertical stack of buttons and prefer the capsule shape in a horizontal row of buttons." [https://developer.apple.com/design/human-interface-guidelines/buttons]

## Alerts

- Content: alerts show "a title, optional informative text, and up to three buttons." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- Order: "place the button people are most likely to choose on the trailing side in a row of buttons or at the top in a stack of buttons." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- Default: "Always place the default button on the trailing side of a row or at the top of a stack." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- Cancel: "Cancel buttons are typically on the leading side of a row or at the bottom of a stack." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- Cancel title: "Always use “Cancel” to title a button that cancels the alert’s action." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- Cancel is not default: "you don’t want to make a Cancel button the default button." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- Destructive: "Use the destructive style to identify a button that performs a destructive action people didn’t deliberately choose." "If there’s a destructive action, include a Cancel button". [https://developer.apple.com/design/human-interface-guidelines/alerts]

## Sheets

- Buttons: "The Cancel (or Close) button dismisses a sheet without saving any changes." "The Done button dismisses a sheet after completing a task or explicitly saving changes." [https://developer.apple.com/design/human-interface-guidelines/sheets]
- Pair: "If you provide a Done button, always pair it with a Cancel button". [https://developer.apple.com/design/human-interface-guidelines/sheets]
- Limit: "Avoid showing all three buttons — Cancel, Done, and Back — together." [https://developer.apple.com/design/human-interface-guidelines/sheets]
- Placement: "The placement of these buttons varies between platforms". Only iOS and iPadOS get a placement rule: Cancel "on the leading edge of the top toolbar", Done "on the trailing edge". [https://developer.apple.com/design/human-interface-guidelines/sheets]
- macOS size: "Present a sheet in a reasonable default size." [https://developer.apple.com/design/human-interface-guidelines/sheets]
- Inference: the macOS section of the sheets page (changed March 24, 2026) gives no button-placement rule. The alerts order rule (default on the trailing side, Cancel on the leading side) is the nearest macOS rule.

## Sidebars and inspectors

- Sidebar side: "A sidebar appears on the leading side of a view". [https://developer.apple.com/design/human-interface-guidelines/sidebars]
- Hide: "Consider letting people hide the sidebar." "in macOS, you can include a show/hide button or add Show Sidebar and Hide Sidebar commands to your app’s View menu." [https://developer.apple.com/design/human-interface-guidelines/sidebars]
- Default: "Avoid hiding the sidebar by default to ensure that it remains discoverable." [https://developer.apple.com/design/human-interface-guidelines/sidebars]
- macOS resize: "Consider automatically hiding and revealing a sidebar when its container window resizes." [https://developer.apple.com/design/human-interface-guidelines/sidebars]
- The HIG has no inspectors page. The URL `.../inspectors` returns 404. Inspector rules are on other pages:
  - "an inspector, which typically presents information on the trailing side of a split view." [https://developer.apple.com/design/human-interface-guidelines/windows]
  - Toolbar trailing edge holds "buttons that open nearby inspectors". [https://developer.apple.com/design/human-interface-guidelines/toolbars]
  - "An inspector displays the details of the currently selected item, automatically updating its contents when the item changes". "you might also consider using a [split view] pane to present an inspector." [https://developer.apple.com/design/human-interface-guidelines/panels]
- SwiftUI `inspector(isPresented:content:)`: "an inspector can present as a trailing column in a horizontally regular size class". [https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)]
- SwiftUI `inspectorColumnWidth(min:ideal:max:)`: "Sets a flexible, preferred width for the inspector in a trailing-column presentation." Apple's example is ideal 225, max 400, min 150, "at which point it will collapse, if allowed." [https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)]

## Split views

- macOS: "A split view includes dividers between panes that can support dragging to resize them." [https://developer.apple.com/design/human-interface-guidelines/split-views]
- Sizes: "Set reasonable defaults for minimum and maximum pane sizes." "make sure to use sizes that keep the divider visible." [https://developer.apple.com/design/human-interface-guidelines/split-views]
- Hide: "Consider letting people hide a pane when it makes sense." [https://developer.apple.com/design/human-interface-guidelines/split-views]
- Reveal: "Provide multiple ways to reveal hidden panes", for example "a toolbar button or a menu command — including a keyboard shortcut". [https://developer.apple.com/design/human-interface-guidelines/split-views]
- Divider: "Prefer the thin divider style. The thin divider measures one point in width". [https://developer.apple.com/design/human-interface-guidelines/split-views]
- SwiftUI `navigationSplitViewColumnWidth(min:ideal:max:)`: "Only some platforms enable resizing columns." [https://developer.apple.com/documentation/swiftui/view/navigationsplitviewcolumnwidth(min:ideal:max:)]

## Layout

- Order: "place the most important items near the top and leading side of the window or display." [https://developer.apple.com/design/human-interface-guidelines/layout]
- Align: "Align elements to make them easier to scan, and use indentation to convey hierarchy." "People assume that aligned items are related to each other". [https://developer.apple.com/design/human-interface-guidelines/layout]
- Group: "Group related items to clearly express related information or functions." Use "negative space, container shapes, or separator lines". [https://developer.apple.com/design/human-interface-guidelines/layout]
- Adapt: "Design a layout that adapts gracefully and consistently." Respect "system-defined safe areas, margins, and guides". [https://developer.apple.com/design/human-interface-guidelines/layout]
- macOS bottom: "Avoid placing controls or critical information at the bottom of a window." [https://developer.apple.com/design/human-interface-guidelines/layout]
- Spacing: "Use consistent spacing." This rule is in the tvOS grid section only. [https://developer.apple.com/design/human-interface-guidelines/layout]
- Centering: "prefer to keep content horizontally centered at very large sizes". This rule is in the visionOS section only. [https://developer.apple.com/design/human-interface-guidelines/layout]

## Empty states (content unavailable)

- The HIG has no empty-state page. The URL `.../content-unavailable` returns 404. The Components and Patterns indexes list no such page.
- Loading: "Show something as soon as possible." "consider showing placeholder text, graphics, or animations as content loads". [https://developer.apple.com/design/human-interface-guidelines/loading]
- Alerts page: when the app finds a problem at startup, "you could show cached or placeholder data and a nonintrusive label that describes the problem." [https://developer.apple.com/design/human-interface-guidelines/alerts]
- SwiftUI `ContentUnavailableView`: "It is recommended to use `ContentUnavailableView` in situations where a view’s content cannot be displayed." Causes are "a network error, a list without items, a search that returns no results". [https://developer.apple.com/documentation/swiftui/contentunavailableview]
- It takes "a label and some additional content such as a description or a call to action". [https://developer.apple.com/documentation/swiftui/contentunavailableview]
- `init(label:description:actions:)`: the `actions` parameter is "The content of the interface actions." It defaults to `EmptyView()`. [https://developer.apple.com/documentation/swiftui/contentunavailableview/init(label:description:actions:)]
- Apple gives no maximum number of action buttons. Apple gives no button style for the actions slot.

## Toolbars

- macOS: "toolbar items don’t include a bezel." [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Borders: "Prefer system-provided symbols without borders." "Borders (like outlined circle symbols) aren’t necessary because the section provides a visible container". [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Count: "Minimize the number of groups." "In general, aim for a maximum of three." [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Text items: "Keep actions with text labels separate." "Add separation by inserting fixed space between the buttons." [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Locations: leading edge has the sidebar toggle and title; "Items on the trailing edge remain visible at all window sizes." [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Primary: "Use the `.prominent` style for key actions such as Done or Submit." "Only specify one primary action, and put it on the trailing side of the toolbar." [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Groups: "Group toolbar items logically by function and frequency of use." [https://developer.apple.com/design/human-interface-guidelines/toolbars]
- Square and image buttons do not go in a toolbar: "If you need a button in a toolbar, use a toolbar item." [https://developer.apple.com/design/human-interface-guidelines/buttons]

## SwiftUI API facts

- `ControlSize` cases: `mini`, `small`, `regular`, `large`, `extraLarge`. [https://developer.apple.com/documentation/swiftui/controlsize]
- `controlSize(_:)`: "Use `controlSize(_:)` to override the system default size for controls in this view." [https://developer.apple.com/documentation/swiftui/view/controlsize(_:)]
- `.bordered`: "applies the standard border style based on the button’s context." [https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/bordered]
- `.borderedProminent`: "applies the standard bordered prominent style based on the button’s context." [https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/borderedprominent]
- `buttonBorderShape(_:)`: "The border shape affects buttons of the bordered and borderedProminent styles." "In macOS 15 and earlier, some border shapes are only applicable to bordered buttons in widgets." [https://developer.apple.com/documentation/swiftui/view/buttonbordershape(_:)]
- `KeyboardShortcut.defaultAction`: "On macOS, the default button is designated with special coloration. If more than one control is assigned this shortcut, only the first one is emphasized." [https://developer.apple.com/documentation/swiftui/keyboardshortcut/defaultaction]
- Equal widths with `frame(maxWidth: .infinity)`: no Apple rule found.

## Gaps

- The HIG gives no macOS rule that stacked buttons have equal widths. The equal-height rule is for watchOS only.
- The HIG gives no rule that buttons in a macOS row have equal widths. It only says that buttons of the same size form a set, and that different sizes look inconsistent.
- The buttons page gives no macOS push-button size table and no point heights for control sizes.
- The HIG has no inspectors page and no inspector width numbers. The only numbers are in the SwiftUI example (150, 225, 400).
- The HIG gives no minimum or maximum sidebar width.
- The macOS sheets section gives no button-placement rule.
- The HIG has no empty-state page. Apple states no limit for buttons in the `ContentUnavailableView` actions slot, and no style for them.
- The layout page gives no macOS rule for centering or for a spacing scale. "Use consistent spacing" is in the tvOS section only.
- Inference: the buttons rules "Keep the number of prominent buttons to one or two per view" and "Use style — not size" also apply to an empty-state view with actions.

## Sources

- https://developer.apple.com/design/human-interface-guidelines/buttons
- https://developer.apple.com/design/human-interface-guidelines/alerts
- https://developer.apple.com/design/human-interface-guidelines/sheets
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/panels
- https://developer.apple.com/design/human-interface-guidelines/windows
- https://developer.apple.com/design/human-interface-guidelines/split-views
- https://developer.apple.com/design/human-interface-guidelines/layout
- https://developer.apple.com/design/human-interface-guidelines/loading
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/documentation/swiftui/contentunavailableview
- https://developer.apple.com/documentation/swiftui/contentunavailableview/init(label:description:actions:)
- https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)
- https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)
- https://developer.apple.com/documentation/swiftui/view/navigationsplitviewcolumnwidth(min:ideal:max:)
- https://developer.apple.com/documentation/swiftui/controlsize
- https://developer.apple.com/documentation/swiftui/view/controlsize(_:)
- https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/bordered
- https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/borderedprominent
- https://developer.apple.com/documentation/swiftui/view/buttonbordershape(_:)
- https://developer.apple.com/documentation/swiftui/view/buttonstyle(_:)
- https://developer.apple.com/documentation/swiftui/keyboardshortcut/defaultaction

