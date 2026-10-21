pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    objectName: "journalInsights"
    required property var theme
    required property var summary
    readonly property real totalActivities: summary ? summary.openActivities + summary.doneActivities : 0
    spacing: theme.space(20)

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: entriesColumn.implicitHeight + root.theme.space(32)
        color: root.theme.surface
        radius: root.theme.radius
        ColumnLayout {
            id: entriesColumn
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: root.theme.space(16)
            spacing: root.theme.space(18)

            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(6)
                SectionHeading { theme: root.theme; text: "Last 14 days"; Layout.fillWidth: true }
                DText {
                    theme: root.theme
                    Layout.fillWidth: true
                    text: root.summary ? Display.span(root.summary.startDate, root.summary.endDate) : ""
                    color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    wrapMode: Text.Wrap
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(6)
                DText {
                    objectName: "journalEntryCount"
                    theme: root.theme
                    Layout.fillWidth: true
                    text: (root.summary ? root.summary.entryCount : 0) + (root.summary && root.summary.entryCount === 1 ? " entry" : " entries")
                    font.pixelSize: root.theme.heading
                    wrapMode: Text.Wrap
                }
                DText {
                    objectName: "journalActiveDays"
                    theme: root.theme
                    Layout.fillWidth: true
                    text: (root.summary ? root.summary.activeDays : 0) + " of 14 days with entries"
                    color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    wrapMode: Text.Wrap
                }
            }
            EntryBars {
                theme: root.theme
                Layout.fillWidth: true
                days: root.summary ? root.summary.days : []
                counts: root.summary ? root.summary.days.map(day => day.entries) : []
            }
            DText {
                theme: root.theme
                Layout.fillWidth: true
                visible: !root.summary || root.summary.entryCount === 0
                text: "No entries in these 14 days."
                color: root.theme.secondary
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
            }
        }
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: statusColumn.implicitHeight + root.theme.space(32)
        color: root.theme.surface
        radius: root.theme.radius
        ColumnLayout {
            id: statusColumn
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: root.theme.space(16)
            spacing: root.theme.space(12)

            SectionHeading { theme: root.theme; text: "Activities"; hint: "Current status · all activities"; Layout.fillWidth: true }
            DText {
                objectName: "journalActivityCounts"
                theme: root.theme
                Layout.fillWidth: true
                text: (root.summary ? root.summary.openActivities : 0) + " open · " + (root.summary ? root.summary.doneActivities : 0) + " done"
                wrapMode: Text.Wrap
            }
            DText {
                theme: root.theme
                Layout.fillWidth: true
                visible: root.totalActivities === 0
                text: "No activities yet."
                color: root.theme.secondary
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
            }
        }
    }
}
