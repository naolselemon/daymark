import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

Switch {
    id: root
    required property var theme
    property bool value: false
    property string description: ""
    property string helpText: ""
    signal toggleRequested(bool value)
    // The controller's acknowledged value, not a click, paints the switch.
    checked: value
    checkable: false
    onClicked: toggleRequested(!value)
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    spacing: theme.space(14)
    padding: theme.space(4)
    leftPadding: 0
    rightPadding: 0
    font.family: theme.family
    font.pixelSize: theme.body
    implicitWidth: theme.space(260)
    implicitHeight: Math.max(theme.space(44), labels.implicitHeight + topPadding + bottomPadding)
    opacity: enabled ? 1 : 0.45
    Accessible.name: text
    Accessible.description: helpText || description
    Accessible.checkable: true
    Accessible.checked: value
    onActiveFocusChanged: if (activeFocus) Qt.callLater(() => Focus.reveal(root))
    indicator: Rectangle {
        x: root.width - width - root.rightPadding
        y: (root.height - height) / 2
        implicitWidth: root.theme.space(46)
        implicitHeight: root.theme.space(26)
        radius: height / 2
        color: "transparent"
        border.color: root.value ? root.theme.accent : root.theme.border
        Rectangle {
            width: root.theme.space(18)
            height: width
            x: root.value ? parent.width - width - root.theme.space(4) : root.theme.space(4)
            y: (parent.height - height) / 2
            radius: width / 2
            color: root.value ? root.theme.accent : root.theme.secondary
        }
    }
    contentItem: Item {
        implicitHeight: labels.implicitHeight
        Column {
            id: labels
            width: Math.max(0, parent.width - root.indicator.width - root.spacing)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.theme.space(3)
            DText { theme: root.theme; width: parent.width; text: root.text }
            DText {
                theme: root.theme; width: parent.width; text: root.description
                visible: text !== ""; color: root.theme.secondary; font.pixelSize: root.theme.small
            }
        }
    }
    background: Rectangle {
        radius: root.theme.radius
        color: root.down ? root.theme.fill("pressed") : root.hovered ? root.theme.fill("hover-cursor") : "transparent"
        border.color: root.theme.accent
        border.width: root.visualFocus ? Math.max(1, root.theme.strokeWidth("focus")) : 0
    }
    ToolTip {
        id: helpTip
        visible: root.enabled && root.helpText !== "" && (root.hovered || root.visualFocus)
        delay: 650
        text: root.helpText
        padding: root.theme.space(10)
        margins: root.theme.space(8)
        contentItem: DText {
            theme: root.theme; text: helpTip.text
            color: root.theme.hintText; font.pixelSize: root.theme.small
        }
        background: Rectangle {
            color: root.theme.hintBackground
            border.color: Qt.rgba(root.theme.hintText.r, root.theme.hintText.g, root.theme.hintText.b, 0.25)
            radius: root.theme.radius
        }
    }
}
