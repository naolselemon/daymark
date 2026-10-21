import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

Button {
    id: root
    required property var theme
    property bool selected: false
    property bool primary: false
    property bool quiet: false
    property string shortcutHint: ""
    readonly property string paintState: !enabled ? "normal" : down ? "pressed" : visualFocus ? "focus" : hovered ? "hover-cursor" : selected ? "selected" : "normal"
    font.family: theme.family
    font.pixelSize: theme.body
    font.bold: selected || primary
    palette.toolTipBase: theme.background
    palette.toolTipText: theme.foreground
    palette.dark: theme.border
    focusPolicy: Qt.StrongFocus
    onActiveFocusChanged: { if (activeFocus) Qt.callLater(() => Focus.reveal(root)); }
    hoverEnabled: true
    padding: Math.max(theme.source.spacing["control-padding-y"], theme.space(9))
    leftPadding: Math.max(theme.source.spacing["control-padding-x"], theme.space(14))
    rightPadding: leftPadding
    implicitHeight: Math.max(theme.source.spacing["control-height"], theme.space(44), contentItem.implicitHeight + topPadding + bottomPadding + 2)
    implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding + 2
    opacity: enabled ? 1 : 0.45
    contentItem: Text {
        text: root.text
        textFormat: Text.PlainText
        font: root.font
        color: root.primary ? root.theme.accentText : root.selected ? root.theme.accent : root.theme.foreground
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        color: root.primary ? root.theme.accent : root.selected ? root.theme.accentSurface
            : root.quiet && root.paintState === "normal" ? "transparent"
            : root.paintState === "normal" ? root.theme.surface : root.theme.fill(root.paintState)
        radius: root.theme.radius
        border.color: root.visualFocus ? root.theme.accent : root.theme.stroke(root.paintState)
        border.width: root.visualFocus ? Math.max(1, root.theme.strokeWidth("focus"))
            : root.quiet || root.primary ? 0 : root.theme.strokeWidth(root.paintState)
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: root.enabled && (root.primary || root.selected) && (root.down || root.hovered)
            color: root.theme.fill(root.down ? "pressed" : "hover-cursor")
        }
        // Inset contrast keeps keyboard focus distinct even on accent buttons.
        Rectangle {
            anchors.fill: parent
            anchors.margins: root.theme.space(3)
            radius: Math.max(0, parent.radius - root.theme.space(3))
            visible: root.visualFocus
            color: "transparent"
            border.color: root.primary ? root.theme.accentText : root.theme.accent
            border.width: Math.max(1, root.theme.strokeWidth("focus"))
        }
    }
    Accessible.name: text
    Accessible.description: shortcutHint
    ToolTip.visible: enabled && shortcutHint !== "" && (hovered || visualFocus)
    ToolTip.delay: 650
    ToolTip.text: shortcutHint
}
