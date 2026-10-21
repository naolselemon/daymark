import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    required property var theme
    required property var activity
    property bool actionsEnabled: true
    property string contextText: ""
    signal detailsRequested(string activityId)
    signal completeRequested(string activityId)
    implicitHeight: Math.max(theme.space(64), row.implicitHeight + theme.space(16))
    color: "transparent"
    radius: theme.radius
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.leftMargin: root.theme.space(12); anchors.rightMargin: root.theme.space(12); height: 1; color: root.theme.border; opacity: 0.2 }
    RowLayout {
        id: row
        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        anchors.margins: root.theme.space(8)
        spacing: root.theme.space(6)
        DCheckBox {
            id: completionToggle
            theme: root.theme; objectName: "done-" + root.activity.id
            enabled: root.actionsEnabled
            checked: root.activity.status === "done"
            // Only a committed activity snapshot may change the saved state.
            nextCheckState: function() { return completionToggle.checkState; }
            Accessible.name: (root.activity.status === "done" ? "Reopen " : "Mark done: ") + root.activity.title
            onClicked: root.completeRequested(root.activity.id)
        }
        DButton {
            theme: root.theme; quiet: true; objectName: "activity-" + root.activity.id
            Layout.fillWidth: true; implicitWidth: root.theme.space(180)
            implicitHeight: labels.implicitHeight + topPadding + bottomPadding
            contentItem: Column {
                id: labels; spacing: root.theme.space(5)
                DText { theme: root.theme; width: parent.width; text: root.activity.title; font.pixelSize: root.theme.body; maximumLineCount: 2; elide: Text.ElideRight; font.strikeout: root.activity.status === "done"; color: root.activity.status === "done" ? root.theme.secondary : root.theme.foreground }
                DText { theme: root.theme; width: parent.width; text: root.contextText; visible: text !== ""; color: root.theme.secondary; font.pixelSize: root.theme.small; maximumLineCount: 1; elide: Text.ElideRight }
            }
            Accessible.name: root.activity.title + ", open activity"
            onClicked: root.detailsRequested(root.activity.id)
        }
    }
}
