import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var theme
    property string text: ""
    property string hint: ""
    spacing: theme.space(6)
    DText { theme: root.theme; text: root.text; color: root.theme.foreground; font.pixelSize: root.theme.heading; font.bold: true; Layout.fillWidth: true }
    DText { theme: root.theme; text: root.hint; visible: text !== ""; color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
}
