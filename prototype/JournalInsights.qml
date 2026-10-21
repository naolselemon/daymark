pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

ScrollView {
    id: root
    objectName: "journalInsights"
    required property var theme
    required property var summary
    readonly property real totalActivities: summary ? summary.openActivities + summary.doneActivities : 0
    contentWidth: availableWidth
    clip: true
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

    ColumnLayout {
        width: root.availableWidth
        spacing: root.theme.space(20)

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
                    SectionHeading { theme: root.theme; text: "Last 7 days"; Layout.fillWidth: true }
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
                        text: (root.summary ? root.summary.activeDays : 0) + " of 7 days with entries"
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
                    text: "No entries in these seven days."
                    color: root.theme.secondary
                    font.pixelSize: root.theme.small
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
                spacing: root.theme.space(16)

                SectionHeading { theme: root.theme; text: "Activities"; hint: "Current status · all activities"; Layout.fillWidth: true }
                DText {
                    objectName: "journalActivityCounts"
                    theme: root.theme
                    Layout.fillWidth: true
                    text: (root.summary ? root.summary.openActivities : 0) + " open · " + (root.summary ? root.summary.doneActivities : 0) + " done"
                    wrapMode: Text.Wrap
                }
                Rectangle {
                    objectName: "journalCompletionTrack"
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.theme.space(6)
                    color: root.theme.surface
                    radius: root.theme.radius
                    readonly property real completion: root.totalActivities > 0 ? root.summary.doneActivities / root.totalActivities : 0
                    Accessible.role: Accessible.StaticText
                    Accessible.name: (root.summary ? root.summary.doneActivities : 0) + " of " + root.totalActivities + " activities done"
                    Rectangle {
                        width: parent.width * parent.completion
                        height: parent.height
                        color: root.theme.secondary
                        opacity: 0.5
                        radius: root.theme.radius
                    }
                }
                DText {
                    theme: root.theme
                    Layout.fillWidth: true
                    visible: root.totalActivities === 0
                    text: "No activities yet."
                    color: root.theme.secondary
                    font.pixelSize: root.theme.small
                }
            }
        }
    }
}
