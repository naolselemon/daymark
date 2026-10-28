import QtQuick
import QtQuick.Layouts

DButton {
    id: root
    required property var session
    required property var activity
    property bool showIcon: false
    signal detailsRequested(string activityId)
    objectName: "session-" + session.id
    quiet: true
    implicitWidth: theme.space(220)
    implicitHeight: Math.max(theme.space(64), content.implicitHeight + topPadding + bottomPadding)
    leftPadding: theme.space(14); rightPadding: theme.space(14)
    topPadding: theme.space(14); bottomPadding: theme.space(14)
    contentItem: RowLayout {
        id: content
        spacing: root.theme.space(16)
        Rectangle { visible: !root.showIcon; implicitWidth: root.theme.space(3); implicitHeight: root.theme.space(28); Layout.alignment: Qt.AlignTop; Layout.topMargin: root.theme.space(4); color: root.theme.accent; opacity: 0.35 }
        DIcon { visible: root.showIcon; name: "log"; color: root.theme.secondary; Layout.preferredWidth: root.theme.space(20); Layout.preferredHeight: root.theme.space(20); Layout.alignment: Qt.AlignTop; Layout.topMargin: root.theme.space(2) }
        ColumnLayout {
            Layout.fillWidth: true; spacing: root.theme.space(6)
            DText { theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0; text: root.activity ? root.activity.title : "Activity unavailable"; font.pixelSize: root.theme.body; wrapMode: Text.Wrap }
            DText { theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0; text: (root.session.tasks || []).map(task => task.title).join(" · "); visible: text !== ""; color: root.theme.accent; wrapMode: Text.Wrap }
            DText { theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0; text: root.session.note; visible: text !== ""; color: root.theme.secondary; wrapMode: Text.Wrap }
        }
    }
    Accessible.name: (root.activity ? root.activity.title : "Activity unavailable")
        + ((root.session.tasks || []).length ? ", " + root.session.tasks.map(task => task.title).join(", ") : "")
        + (root.session.note ? ", " + root.session.note : "") + ", open activity"
    onClicked: if (root.activity) root.detailsRequested(root.activity.id)
}
