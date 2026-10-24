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
    property string iconName: ""
    property bool iconOnly: iconName !== ""
    readonly property string tooltipText: Accessible.name + (shortcutHint ? " · " + shortcutHint : "")
    readonly property string paintState: !enabled ? "normal" : down ? "pressed" : visualFocus ? "focus" : hovered ? "hover-cursor" : selected ? "selected" : "normal"
    font.family: theme.family
    font.pixelSize: theme.body
    font.bold: selected || primary
    focusPolicy: Qt.StrongFocus
    onActiveFocusChanged: { if (activeFocus) Qt.callLater(() => Focus.reveal(root)); }
    hoverEnabled: true
    padding: Math.max(theme.source.spacing["control-padding-y"], theme.space(9))
    leftPadding: iconOnly ? theme.space(10) : Math.max(theme.source.spacing["control-padding-x"], theme.space(14))
    rightPadding: leftPadding
    implicitHeight: Math.max(theme.source.spacing["control-height"], theme.space(44), contentItem.implicitHeight + topPadding + bottomPadding + 2)
    implicitWidth: Math.max(theme.space(44), contentItem.implicitWidth + leftPadding + rightPadding + 2)
    opacity: enabled ? 1 : 0.45
    FontMetrics { id: labelMetrics; font: root.font }
    contentItem: Item {
        implicitWidth: root.iconOnly ? root.theme.space(22)
            : label.implicitWidth + (root.iconName ? root.theme.space(30) : 0)
        implicitHeight: Math.max(root.iconOnly ? 0 : labelMetrics.height, root.iconName ? root.theme.space(22) : 0)
        DIcon {
            anchors.verticalCenter: parent.verticalCenter
            x: root.iconOnly ? (parent.width - width) / 2 : 0
            width: root.theme.space(22)
            height: width
            visible: root.iconName !== ""
            name: root.iconName
            color: root.selected && !root.primary ? root.theme.accent : root.theme.foreground
        }
        Text {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            x: root.iconName ? root.theme.space(30) : 0
            width: Math.max(0, parent.width - x)
            visible: !root.iconOnly
            text: root.text
            textFormat: Text.PlainText
            font: root.font
            color: root.selected && !root.primary ? root.theme.accent : root.theme.foreground
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    background: Rectangle {
        color: root.primary || root.selected ? root.theme.accentSurface
            : root.quiet && root.paintState === "normal" ? "transparent"
            : root.paintState === "normal" ? root.theme.controlSurface : root.theme.fill(root.paintState)
        radius: root.theme.radius
        border.color: root.visualFocus || root.primary ? root.theme.accent : root.theme.stroke(root.paintState)
        border.width: root.visualFocus ? Math.max(1, root.theme.strokeWidth("focus"))
            : root.primary ? 1 : root.quiet ? 0 : root.theme.strokeWidth(root.paintState)
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
            border.color: root.primary ? root.theme.foreground : root.theme.accent
            border.width: Math.max(1, root.theme.strokeWidth("focus"))
        }
    }
    Accessible.name: text
    Accessible.description: shortcutHint
    ToolTip {
        id: shortcutTip
        objectName: "shortcutHint"
        visible: root.enabled && (root.iconName !== "" || root.shortcutHint !== "") && (root.hovered || root.visualFocus)
        delay: 650
        text: root.tooltipText
        padding: root.theme.space(10)
        margins: root.theme.space(8)
        contentItem: DText {
            theme: root.theme
            text: shortcutTip.text
            color: root.theme.hintText
            font.pixelSize: root.theme.small
            font.italic: true
        }
        background: Rectangle {
            color: root.theme.hintBackground
            border.color: Qt.rgba(root.theme.hintText.r, root.theme.hintText.g, root.theme.hintText.b, 0.25)
            radius: root.theme.radius
        }
    }
}
