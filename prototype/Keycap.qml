import QtQuick

Rectangle {
    id: root
    required property var theme
    property string text: ""
    implicitWidth: label.implicitWidth + theme.space(14)
    implicitHeight: label.implicitHeight + theme.space(8)
    radius: Math.min(theme.radius, theme.space(4))
    color: theme.controlSurface
    border.color: Qt.rgba(theme.foreground.r, theme.foreground.g, theme.foreground.b, 0.18)
    DText {
        id: label
        anchors.centerIn: parent
        theme: root.theme
        text: root.text
        font.pixelSize: root.theme.small
        color: root.theme.foreground
        wrapMode: Text.NoWrap
    }
}
