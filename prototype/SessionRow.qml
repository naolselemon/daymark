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
    implicitHeight: Math.max(theme.space(48), content.implicitHeight + topPadding + bottomPadding)
    leftPadding: theme.space(6); rightPadding: theme.space(6)
    topPadding: theme.space(8); bottomPadding: theme.space(8)
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: root.theme.border; opacity: 0.45 }
    contentItem: RowLayout {
        id: content
        spacing: root.theme.space(10)
        Rectangle { visible: !root.showIcon; implicitWidth: root.theme.space(2); implicitHeight: root.theme.space(20); Layout.alignment: Qt.AlignTop; Layout.topMargin: root.theme.space(4); color: root.theme.accent; opacity: 0.65 }
        DIcon { visible: root.showIcon; name: "log"; color: root.theme.secondary; Layout.preferredWidth: root.theme.space(20); Layout.preferredHeight: root.theme.space(20); Layout.alignment: Qt.AlignTop; Layout.topMargin: root.theme.space(2) }
        ColumnLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(3)
            DText { theme: root.theme; objectName: "sessionTitle-" + root.session.id; Layout.fillWidth: true; Layout.minimumWidth: 0; text: root.activity ? root.activity.title : "Activity unavailable"; font.pixelSize: root.theme.body; maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap; font.strikeout: !!root.activity && root.activity.status === "done"; color: root.activity && root.activity.status === "done" ? root.theme.secondary : root.theme.foreground }
            DText { theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0; text: (root.session.tasks || []).map(task => task.title).join(" · "); visible: text !== ""; color: root.theme.accent; font.pixelSize: root.theme.small; maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap }
            DText { theme: root.theme; objectName: "sessionNote-" + root.session.id; Layout.fillWidth: true; Layout.minimumWidth: 0; text: root.session.note; visible: text !== ""; color: root.theme.secondary; maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap }
        }
        DIcon { objectName: "sessionDone-" + root.session.id; visible: !!root.activity && root.activity.status === "done"; name: "check"; color: root.theme.accent; Layout.preferredWidth: root.theme.space(20); Layout.preferredHeight: root.theme.space(20); Layout.alignment: Qt.AlignTop; Layout.topMargin: root.theme.space(2) }
    }
    Accessible.name: (root.activity ? root.activity.title : "Activity unavailable")
        + (root.activity && root.activity.status === "done" ? ", completed" : "")
        + ((root.session.tasks || []).length ? ", " + root.session.tasks.map(task => task.title).join(", ") : "")
        + (root.session.note ? ", " + root.session.note : "") + ", open activity"
    onClicked: if (root.activity) root.detailsRequested(root.activity.id)
}
