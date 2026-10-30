pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

Rectangle {
    id: root
    objectName: "activityInsights"
    required property var theme
    required property var stats
    required property var days
    property bool expanded: false
    readonly property bool wide: width >= theme.space(760)
    readonly property int recentActiveDays: stats && stats.recentCounts
        ? stats.recentCounts.reduce((total, count) => total + (count > 0 ? 1 : 0), 0) : 0
    implicitHeight: content.implicitHeight + theme.space(16)
    color: "transparent"
    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: root.theme.border }
    ColumnLayout {
        id: content
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.topMargin: root.theme.space(8)
        spacing: root.theme.space(8)
        DisclosureHeading {
            theme: root.theme; title: qsTr("Activity insights"); Layout.fillWidth: true
            objectName: "activityInsightsToggle"; summary: qsTr("All time")
            expanded: root.expanded; onClicked: root.expanded = !root.expanded
        }
        GridLayout {
            objectName: "activityAllTimeMetrics"
            Layout.fillWidth: true; Layout.minimumWidth: 0
            columns: width >= root.theme.space(340) ? 3 : 1
            uniformCellWidths: true
            columnSpacing: root.theme.space(12); rowSpacing: root.theme.space(6)
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                DText { theme: root.theme; objectName: "activityTotalEntries"; text: root.stats ? root.stats.entryCount : 0; font.pixelSize: root.theme.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                DText { theme: root.theme; text: qsTr("total entries"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
            }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                DText { theme: root.theme; objectName: "activityDistinctDays"; text: root.stats ? root.stats.activeDays : 0; font.pixelSize: root.theme.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                DText { theme: root.theme; text: qsTr("days logged"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
            }
            DText {
                theme: root.theme; objectName: "activityLastEntry"
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: root.stats && root.stats.lastDate ? qsTr("Last entry: ") + Display.day(root.stats.lastDate) : qsTr("Nothing logged yet")
                color: root.theme.secondary; font.pixelSize: root.theme.small; wrapMode: Text.Wrap
            }
        }
        GridLayout {
            visible: root.expanded
            Layout.fillWidth: true; Layout.minimumWidth: 0
            columns: root.wide ? 2 : 1
            columnSpacing: root.theme.space(20); rowSpacing: root.theme.space(12)
            EntryCalendar {
                theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                Layout.preferredWidth: root.theme.space(460); Layout.alignment: Qt.AlignTop
                days: root.days || []; counts: root.stats ? root.stats.recentCounts : []
            }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.preferredWidth: root.theme.space(220); Layout.alignment: Qt.AlignTop
                spacing: root.theme.space(8)
                SectionHeading { theme: root.theme; text: qsTr("This window"); Layout.fillWidth: true }
                GridLayout {
                    objectName: "activityWindowMetrics"
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    columns: root.wide ? 1 : 2
                    columnSpacing: root.theme.space(12); rowSpacing: root.theme.space(8)
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                        DText { theme: root.theme; objectName: "activityRecentEntries"; text: root.stats ? root.stats.recentEntries : 0; font.pixelSize: root.theme.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        DText { theme: root.theme; text: qsTr("entries / 14 days"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                        DText { theme: root.theme; text: root.recentActiveDays + " / 14"; font.pixelSize: root.theme.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        DText { theme: root.theme; text: qsTr("days with entries"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
                    }
                }
            }
        }
    }
}
