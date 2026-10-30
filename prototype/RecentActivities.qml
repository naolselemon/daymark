pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "recentActivities"
    required property var theme
    required property var summary
    required property var activitiesById
    property bool compact: false
    readonly property var recentRows: summary ? summary.recentActivityIds.map(id => ({
        id: id, entries: summary.byActivity[id].recentEntries
    })) : []
    signal activityRequested(string id)
    implicitHeight: content.implicitHeight + (compact ? 0 : theme.space(24))
    color: compact ? "transparent" : theme.surface
    radius: theme.radius

    ColumnLayout {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: root.compact ? 0 : root.theme.space(12)
        spacing: root.theme.space(root.compact ? 4 : 12)

        SectionHeading {
            theme: root.theme
            Layout.fillWidth: true
            Layout.margins: root.compact ? 0 : root.theme.space(8)
            text: "Recent activities"
            hint: root.compact ? "" : "Entries in last 14 days · up to 5 activities"
        }
        Repeater {
            model: root.recentRows
            delegate: DButton {
                id: activityButton
                required property var modelData
                readonly property var activity: root.activitiesById[modelData.id]
                readonly property real entries: modelData.entries
                objectName: "insightActivity-" + modelData.id
                theme: root.theme
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                quiet: true
                text: activity ? activity.title : ""
                leftPadding: root.theme.space(8)
                rightPadding: root.theme.space(8)
                topPadding: root.theme.space(root.compact ? 8 : 12)
                bottomPadding: root.theme.space(root.compact ? 8 : 12)
                onClicked: root.activityRequested(modelData.id)
                Accessible.name: text + ", " + entries + (entries === 1 ? " entry in last 14 days" : " entries in last 14 days")
                contentItem: RowLayout {
                    spacing: root.theme.space(8)
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                        spacing: root.theme.space(6)
                        DText {
                            theme: root.theme
                            Layout.fillWidth: true
                            text: activityButton.text
                            wrapMode: Text.Wrap
                            maximumLineCount: root.compact ? 2 : 2147483647
                            elide: root.compact ? Text.ElideRight : Text.ElideNone
                            Accessible.ignored: true
                        }
                        DText {
                            theme: root.theme
                            Layout.fillWidth: true
                            visible: !root.compact
                            text: activityButton.entries + (activityButton.entries === 1 ? " entry" : " entries")
                            color: root.theme.secondary
                            font.pixelSize: root.theme.small
                            wrapMode: Text.Wrap
                            Accessible.ignored: true
                        }
                    }
                    DIcon { visible: root.compact; name: "next"; color: root.theme.secondary; Layout.preferredWidth: root.theme.space(16); Layout.preferredHeight: root.theme.space(16) }
                }
            }
        }
        DText {
            theme: root.theme
            Layout.fillWidth: true
            Layout.margins: root.theme.space(8)
            visible: root.recentRows.length === 0
            text: "No activity entries in the last 14 days. Entries you save will appear here."
            color: root.theme.secondary
            font.pixelSize: root.theme.small
            wrapMode: Text.Wrap
        }
    }
}
