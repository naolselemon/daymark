pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "recentActivities"
    required property var theme
    required property var summary
    required property var activitiesById
    readonly property var recentIds: summary ? summary.recentActivityIds : []
    readonly property real maximum: recentIds.reduce((maximum, id) => Math.max(maximum, summary.byActivity[id].recentEntries), 0)
    signal activityRequested(string id)
    implicitHeight: content.implicitHeight + theme.space(24)
    color: theme.surface
    radius: theme.radius

    ColumnLayout {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: root.theme.space(12)
        spacing: root.theme.space(8)

        SectionHeading {
            theme: root.theme
            Layout.fillWidth: true
            Layout.margins: root.theme.space(8)
            text: "Recent activities"
            hint: "Entries in last 7 days · up to 5 activities"
        }
        Repeater {
            model: root.recentIds
            delegate: DButton {
                id: activityButton
                required property string modelData
                readonly property var activity: root.activitiesById[modelData]
                readonly property real entries: root.summary.byActivity[modelData].recentEntries
                objectName: "insightActivity-" + modelData
                theme: root.theme
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                quiet: true
                text: activity ? activity.title : ""
                leftPadding: root.theme.space(8)
                rightPadding: root.theme.space(8)
                topPadding: root.theme.space(12)
                bottomPadding: root.theme.space(12)
                onClicked: root.activityRequested(modelData)
                Accessible.name: text + ", " + entries + (entries === 1 ? " entry in last 7 days" : " entries in last 7 days")
                contentItem: ColumnLayout {
                    spacing: root.theme.space(10)
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: activityButton.text
                        wrapMode: Text.Wrap
                        Accessible.ignored: true
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: activityButton.entries + (activityButton.entries === 1 ? " entry" : " entries")
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                        wrapMode: Text.Wrap
                        Accessible.ignored: true
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.theme.space(6)
                        color: root.theme.surface
                        radius: root.theme.radius
                        Rectangle {
                            width: root.maximum > 0 ? parent.width * activityButton.entries / root.maximum : 0
                            height: parent.height
                            color: root.theme.secondary
                            opacity: 0.5
                            radius: root.theme.radius
                        }
                    }
                }
            }
        }
        DText {
            theme: root.theme
            Layout.fillWidth: true
            Layout.margins: root.theme.space(8)
            visible: root.recentIds.length === 0
            text: "No activity entries in the last 7 days. Entries you save will appear here."
            color: root.theme.secondary
            font.pixelSize: root.theme.small
        }
    }
}
