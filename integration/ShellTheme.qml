import QtQuick
import qs.Commons as Commons
import "../prototype/Palette.js" as Palette

// The workspace's small theme interface, bound to the installed shell tokens.
QtObject {
    id: root
    property bool barSurface: false
    // The installed shell exposes these extensible groups as QtObject.
    readonly property var colorTokens: barSurface ? Commons.Color.bar : Commons.Color.popups
    readonly property var fontTokens: Commons.Style.font
    readonly property var spacingTokens: Commons.Style.spacing
    readonly property color background: colorTokens.background
    readonly property color foreground: colorTokens.text
    readonly property color accent: Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent
    readonly property color secondary: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.74)
    readonly property color border: Commons.Style.normalBorderFor(foreground, accent, urgent)
    readonly property color surface: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.045)
    readonly property color accentSurface: Qt.rgba(accent.r, accent.g, accent.b, 0.10)
    readonly property color accentText: Palette.ink(root.accent, root.background, root.foreground)
    readonly property real radius: Commons.Style.cornerRadius
    readonly property string family: fontTokens.family
    readonly property real body: fontTokens.title
    readonly property real small: fontTokens.body
    readonly property real heading: fontTokens.heading
    readonly property real display: fontTokens.display
    readonly property real title: fontTokens.display
    readonly property real pageTitle: fontTokens.displayLarge
    readonly property real gap: spacingTokens.controlGap
    readonly property real padding: spacingTokens.panelPadding
    readonly property var source: ({spacing: {
        "input-padding-y": spacingTokens.inputPaddingY,
        "control-padding-x": spacingTokens.controlPaddingX,
        "control-padding-y": spacingTokens.controlPaddingY,
        "control-height": spacingTokens.controlHeight
    }})
    function space(px) { return Commons.Style.space(px); }
    function fill(state) {
        switch (state) {
        case "hover-cursor": return Commons.Style.hoverFillFor(foreground, accent, urgent);
        case "selected": return Commons.Style.selectedFillFor(foreground, accent, urgent);
        case "pressed": return Commons.Style.pressedFillFor(foreground, accent, urgent);
        case "focus": return Commons.Style.focusFillFor(foreground, accent, urgent);
        case "selection": return Commons.Style.selectionFillFor(foreground, accent, urgent);
        default: return Commons.Style.normalFillFor(foreground, accent, urgent);
        }
    }
    function stroke(state) {
        switch (state) {
        case "hover-cursor": case "pressed": return Commons.Style.hoverBorderFor(foreground, accent, urgent);
        case "selected": return Commons.Style.selectedBorderFor(foreground, accent, urgent);
        case "focus": return Commons.Style.focusBorderFor(foreground, accent, urgent);
        case "selection": return "transparent";
        default: return Commons.Style.normalBorderFor(foreground, accent, urgent);
        }
    }
    function strokeWidth(state) {
        switch (state) {
        case "hover-cursor": case "pressed": return Commons.Style.hoverBorderWidth;
        case "selected": return Commons.Style.selectedBorderWidth;
        case "focus": return Commons.Style.focusBorderWidth;
        case "selection": return 0;
        default: return Commons.Style.normalBorderWidth;
        }
    }
}
