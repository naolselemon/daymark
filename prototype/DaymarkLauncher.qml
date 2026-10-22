import QtQuick
import QtQuick.Controls.Basic

// Development-host launcher; the installed bar uses its native WidgetButton.
DButton {
    id: root
    required property var store
    property bool vertical: false
    readonly property bool tooltipHovered: visible && enabled && hovered
    readonly property string statusText: !store.loaded
        ? (store.lastError ? "Daymark · unavailable" : "Daymark · loading")
        : store.legacyError ? "Daymark · older entries need attention" : "Open Daymark"
    signal openRequested()
    objectName: "daymarkLauncher"
    text: vertical ? "DM" : "Daymark"
    implicitWidth: vertical ? theme.space(40) : contentItem.implicitWidth + leftPadding + rightPadding
    leftPadding: vertical ? theme.space(2) : theme.source.spacing["control-padding-x"]
    rightPadding: leftPadding
    Accessible.name: statusText
    onClicked: openRequested()
    ToolTip {
        visible: root.tooltipHovered
        delay: 500
        timeout: 5000
        padding: root.theme.space(8)
        contentItem: DText { theme: root.theme; text: root.statusText; font.pixelSize: root.theme.small; font.italic: true; color: root.theme.hintText }
        background: Rectangle {
            color: root.theme.hintBackground
            border.color: Qt.rgba(root.theme.hintText.r, root.theme.hintText.g, root.theme.hintText.b, 0.25)
            radius: root.theme.radius
        }
    }
}
