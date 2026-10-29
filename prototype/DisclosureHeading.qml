import QtQuick
import QtQuick.Layouts

DButton {
    id: root
    required property string title
    property string summary: ""
    property bool expanded: false
    readonly property bool inlineSummary: width >= theme.space(560)
    implicitWidth: theme.space(280)
    quiet: true
    text: title
    iconName: expanded ? "collapse" : "expand"
    leftPadding: 0; rightPadding: theme.space(4)
    Accessible.description: (expanded ? qsTr("Expanded") : qsTr("Collapsed"))
        + (summary ? ", " + summary : "")
    contentItem: RowLayout {
        spacing: root.theme.space(16)
        ColumnLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: root.theme.space(4)
            RowLayout {
                Layout.fillWidth: true; spacing: root.theme.space(24)
                DText { theme: root.theme; text: root.title; Layout.fillWidth: true; Layout.minimumWidth: 0 }
                DText { theme: root.theme; text: root.summary; visible: root.inlineSummary && text !== ""; color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.maximumWidth: root.width / 2 }
            }
            DText { theme: root.theme; text: root.summary; visible: !root.inlineSummary && text !== ""; color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
        }
        DIcon { name: root.iconName; color: root.theme.secondary; Layout.preferredWidth: root.theme.space(18); Layout.preferredHeight: root.theme.space(18) }
    }
}
