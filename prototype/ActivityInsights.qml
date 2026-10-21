pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

Rectangle {
    id: root
    objectName: "activityInsights"
    required property var theme
    required property var activity
    required property var stats
    required property var days
    property bool showTitle: true
    implicitHeight: content.implicitHeight + theme.space(32)
    color: theme.surface
    radius: theme.radius

    ColumnLayout {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: root.theme.space(16)
        spacing: root.theme.space(24)

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.showTitle
            spacing: root.theme.space(10)
            SectionHeading { theme: root.theme; text: "Activity entries"; Layout.fillWidth: true }
            DText {
                objectName: "insightActivityTitle"
                theme: root.theme
                Layout.fillWidth: true
                text: root.activity ? root.activity.title : ""
                font.pixelSize: root.theme.heading
                wrapMode: Text.Wrap
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            DText {
                objectName: "activityTotalEntries"
                theme: root.theme
                Layout.fillWidth: true
                text: (root.stats ? root.stats.entryCount : 0) + (root.stats && root.stats.entryCount === 1 ? " total entry" : " total entries")
                font.pixelSize: root.theme.heading
                wrapMode: Text.Wrap
            }
            DText {
                objectName: "activityDistinctDays"
                theme: root.theme
                Layout.fillWidth: true
                text: (root.stats ? root.stats.activeDays : 0) + (root.stats && root.stats.activeDays === 1 ? " day logged · all time" : " days logged · all time")
                color: root.theme.secondary
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
            }
            DText {
                objectName: "activityLastEntry"
                theme: root.theme
                Layout.fillWidth: true
                text: root.stats && root.stats.lastDate ? "Last entry: " + Display.day(root.stats.lastDate) : "Nothing logged yet"
                color: root.theme.secondary
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
            }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.theme.space(1)
            color: root.theme.border
            opacity: 0.5
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(18)
            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(6)
                SectionHeading { theme: root.theme; text: "Last 14 days"; Layout.fillWidth: true }
                DText {
                    theme: root.theme
                    Layout.fillWidth: true
                    text: root.days && root.days.length ? Display.span(root.days[0].date, root.days[root.days.length - 1].date) : ""
                    color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    font.italic: true
                    wrapMode: Text.Wrap
                }
            }
            DText {
                objectName: "activityRecentEntries"
                theme: root.theme
                Layout.fillWidth: true
                text: (root.stats ? root.stats.recentEntries : 0) + (root.stats && root.stats.recentEntries === 1 ? " entry in last 14 days" : " entries in last 14 days")
                wrapMode: Text.Wrap
            }
            EntryBars {
                theme: root.theme
                Layout.fillWidth: true
                days: root.days || []
                counts: root.stats ? root.stats.recentCounts : []
            }
        }
    }
}
