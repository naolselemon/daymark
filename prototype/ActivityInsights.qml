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
    readonly property bool wide: width >= theme.space(920)
    readonly property bool tabletMetrics: !wide && width >= Math.max(theme.space(560),
        3 * Math.max(
            smallMetrics.boundingRect("entries / 14 days").width,
            smallMetrics.boundingRect("days with entries").width,
            smallMetrics.boundingRect("Last entry:").width,
            smallMetrics.boundingRect("Nothing logged").width,
            displayMetrics.boundingRect(totalEntries.text).width,
            displayMetrics.boundingRect(distinctDays.text).width,
            displayMetrics.boundingRect(recentEntries.text).width,
            displayMetrics.boundingRect(recentDays.text).width) + theme.space(88))
    FontMetrics { id: smallMetrics; font.family: root.theme.family; font.pixelSize: root.theme.small }
    FontMetrics { id: displayMetrics; font.family: root.theme.family; font.pixelSize: root.theme.display }
    readonly property int recentActiveDays: stats && stats.recentCounts
        ? stats.recentCounts.reduce((total, count) => total + (count > 0 ? 1 : 0), 0) : 0
    implicitHeight: content.implicitHeight + theme.space(40)
    color: theme.surface
    radius: theme.radius
    border.color: Qt.rgba(theme.border.r, theme.border.g, theme.border.b, theme.border.a * 0.4)

    GridLayout {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: root.theme.space(20)
        columns: root.wide ? 3 : 1
        columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(24)

        ColumnLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.preferredWidth: root.theme.space(180); Layout.alignment: Qt.AlignTop
            spacing: root.theme.space(8)
            RowLayout {
                Layout.fillWidth: true
                SectionHeading { theme: root.theme; text: "All time"; Layout.fillWidth: true }
                DButton {
                    theme: root.theme; quiet: true; visible: !root.wide
                    objectName: "activityInsightsToggle"
                    text: root.expanded ? "Hide insight details" : "Show insight details"
                    iconName: root.expanded ? "collapse" : "expand"
                    Accessible.description: root.expanded ? "Expanded" : "Collapsed"
                    onClicked: root.expanded = !root.expanded
                }
            }
            GridLayout {
                objectName: "activityAllTimeMetrics"
                Layout.fillWidth: true
                columns: root.tabletMetrics ? 3 : 1
                columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(8)
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: root.theme.space(8)
                    DText {
                        id: totalEntries
                        objectName: "activityTotalEntries"
                        theme: root.theme; Layout.fillWidth: true
                        text: root.stats ? root.stats.entryCount : 0
                        font.pixelSize: root.theme.display
                        wrapMode: Text.Wrap
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true
                        text: "total entries"
                        color: root.theme.secondary; font.pixelSize: root.theme.small
                        wrapMode: Text.Wrap
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: root.theme.space(8)
                    DText {
                        id: distinctDays
                        objectName: "activityDistinctDays"
                        theme: root.theme; Layout.fillWidth: true
                        text: root.stats ? root.stats.activeDays : 0
                        font.pixelSize: root.theme.display
                        wrapMode: Text.Wrap
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true
                        text: "days logged"
                        color: root.theme.secondary; font.pixelSize: root.theme.small
                        wrapMode: Text.Wrap
                    }
                }
                DText {
                    id: lastEntry
                    objectName: "activityLastEntry"
                    theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    text: root.stats && root.stats.lastDate ? "Last entry: " + Display.day(root.stats.lastDate) : "Nothing logged yet"
                    color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    wrapMode: Text.Wrap
                }
            }
        }
        EntryCalendar {
            visible: root.wide || root.expanded
            theme: root.theme
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.preferredWidth: root.theme.space(440); Layout.alignment: Qt.AlignTop
            days: root.days || []
            counts: root.stats ? root.stats.recentCounts : []
        }
        ColumnLayout {
            visible: root.wide || root.expanded
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.preferredWidth: root.theme.space(200); Layout.alignment: Qt.AlignTop
            spacing: root.theme.space(8)
            SectionHeading { theme: root.theme; text: "This window"; Layout.fillWidth: true }
            GridLayout {
                objectName: "activityWindowMetrics"
                Layout.fillWidth: true
                columns: root.tabletMetrics ? 2 : 1
                columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(8)
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: root.theme.space(8)
                    DText {
                        id: recentEntries
                        objectName: "activityRecentEntries"
                        theme: root.theme; Layout.fillWidth: true
                        text: root.stats ? root.stats.recentEntries : 0
                        font.pixelSize: root.theme.display
                        wrapMode: Text.Wrap
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true
                        text: "entries / 14 days"
                        color: root.theme.secondary; font.pixelSize: root.theme.small
                        wrapMode: Text.Wrap
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: root.theme.space(8)
                    DText {
                        id: recentDays
                        theme: root.theme; Layout.fillWidth: true
                        text: root.recentActiveDays + " / 14"
                        font.pixelSize: root.theme.display
                        wrapMode: Text.Wrap
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true
                        text: "days with entries"
                        color: root.theme.secondary; font.pixelSize: root.theme.small
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}
