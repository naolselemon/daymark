import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

TextField {
    id: root
    required property var theme
    readonly property string paintState: activeFocus ? "focus" : hovered ? "hover-cursor" : "normal"
    font.family: theme.family
    font.pixelSize: theme.body
    color: theme.foreground
    placeholderTextColor: theme.secondary
    selectionColor: theme.fill("selection")
    selectedTextColor: theme.foreground
    padding: Math.max(theme.source.spacing["input-padding-y"], theme.space(12))
    leftPadding: Math.max(theme.source.spacing["control-padding-x"], theme.space(14))
    rightPadding: leftPadding
    implicitHeight: contentHeight + topPadding + bottomPadding + 2
    selectByMouse: true
    onActiveFocusChanged: { if (activeFocus) Qt.callLater(() => Focus.reveal(root)); }
    background: Rectangle {
        color: root.theme.controlSurface
        radius: root.theme.radius
        border.color: root.activeFocus ? root.theme.accent : root.theme.stroke(root.paintState)
        border.width: root.activeFocus ? Math.max(1, root.theme.strokeWidth("focus")) : 0
    }
    Accessible.name: placeholderText
}
