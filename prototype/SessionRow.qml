import QtQuick
import QtQuick.Layouts

DButton {
    id: root
    required property var session
    required property var activity
    signal detailsRequested(string activityId)
    objectName: "session-" + session.id
    quiet: true
    implicitWidth: theme.space(220)
    implicitHeight: content.implicitHeight + topPadding + bottomPadding
    leftPadding: theme.space(4)
    contentItem: RowLayout {
        id: content
        spacing: root.theme.space(16)
        Rectangle { implicitWidth: root.theme.space(3); Layout.fillHeight: true; color: root.theme.accentSurface }
        ColumnLayout {
            Layout.fillWidth: true; spacing: root.theme.space(6)
            DText { theme: root.theme; Layout.fillWidth: true; text: root.activity ? root.activity.title : "Activity unavailable"; font.pixelSize: root.theme.heading; maximumLineCount: 2; elide: Text.ElideRight }
            DText { theme: root.theme; Layout.fillWidth: true; text: root.session.note; visible: text !== ""; color: root.theme.secondary; maximumLineCount: 2; elide: Text.ElideRight }
        }
    }
    Accessible.name: (root.activity ? root.activity.title : "Activity unavailable") + ", open activity"
    onClicked: if (root.activity) root.detailsRequested(root.activity.id)
}
