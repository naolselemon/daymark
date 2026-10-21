import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

CheckBox {
    id: root
    required property var theme
    font.family: theme.family
    font.pixelSize: theme.body
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    padding: theme.space(8)
    spacing: theme.space(10)
    indicator.implicitWidth: theme.space(24)
    indicator.implicitHeight: theme.space(24)
    implicitHeight: Math.max(theme.space(44), theme.source.spacing["control-height"],
        implicitContentHeight + topPadding + bottomPadding,
        implicitIndicatorHeight + topPadding + bottomPadding)
    implicitWidth: Math.max(theme.space(44), implicitContentWidth + leftPadding + rightPadding,
        implicitIndicatorWidth + leftPadding + rightPadding)
    opacity: enabled ? 1 : 0.45
    palette.windowText: theme.foreground
    palette.buttonText: theme.foreground
    palette.text: checked ? theme.accentText : theme.foreground
    palette.base: checked ? theme.accent : theme.controlSurface
    palette.light: checked ? theme.accent : theme.fill("pressed")
    palette.mid: checked || hovered ? theme.accent : theme.secondary
    palette.highlight: theme.accent
    palette.highlightedText: theme.accentText
    background: Rectangle {
        radius: root.theme.radius
        color: !root.enabled ? "transparent" : root.down ? root.theme.fill("pressed")
            : root.hovered ? root.theme.fill("hover-cursor") : "transparent"
        border.color: root.theme.accent
        border.width: root.visualFocus ? Math.max(1, root.theme.strokeWidth("focus")) : 0
    }
    onActiveFocusChanged: if (activeFocus) Qt.callLater(() => Focus.reveal(root))
}
