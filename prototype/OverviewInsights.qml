pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "overviewInsights"
    required property var theme
    required property var summary
    required property var activitiesById
    property bool expanded: false
    readonly property bool wide: width >= theme.space(920)
    readonly property bool tabletMetrics: !wide && width >= Math.max(theme.space(560),
        3 * Math.max(
            smallMetrics.boundingRect("entries / 14 days").width,
            smallMetrics.boundingRect("days with entries").width,
            bodyMetrics.boundingRect(activityCounts.text).width,
            displayMetrics.boundingRect(entryCount.text).width,
            displayMetrics.boundingRect(activeDays.text).width) + theme.space(88))
    FontMetrics { id: smallMetrics; font.family: root.theme.family; font.pixelSize: root.theme.small }
    FontMetrics { id: bodyMetrics; font.family: root.theme.family; font.pixelSize: root.theme.body }
    FontMetrics { id: displayMetrics; font.family: root.theme.family; font.pixelSize: root.theme.display }
    signal activityRequested(string id)
    implicitHeight: content.implicitHeight + theme.space(40)
    color: theme.surface
    radius: theme.radius
    border.color: Qt.rgba(theme.border.r, theme.border.g, theme.border.b, theme.border.a * 0.4)

    GridLayout {
        id: content
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.margins: root.theme.space(20)
        columns: root.wide ? 3 : 1
        columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(24)
        ColumnLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.preferredWidth: root.theme.space(180); Layout.alignment: Qt.AlignTop
            spacing: root.theme.space(8)
            RowLayout {
                Layout.fillWidth: true
                SectionHeading { theme: root.theme; text: "14-day insights"; Layout.fillWidth: true }
                DButton {
                    theme: root.theme; quiet: true; visible: !root.wide
                    objectName: "overviewInsightsToggle"
                    text: root.expanded ? "Hide insight details" : "Show insight details"
                    iconName: root.expanded ? "collapse" : "expand"
                    Accessible.description: root.expanded ? "Expanded" : "Collapsed"
                    onClicked: root.expanded = !root.expanded
                }
            }
            GridLayout {
                objectName: "overviewSummaryMetrics"
                Layout.fillWidth: true
                columns: root.tabletMetrics ? 3 : 1
                columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(8)
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: root.theme.space(8)
                    DText {
                        id: entryCount
                        objectName: "overviewEntryCount"
                        theme: root.theme; Layout.fillWidth: true
                        text: root.summary ? root.summary.entryCount : 0
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
                        id: activeDays
                        theme: root.theme; Layout.fillWidth: true
                        text: (root.summary ? root.summary.activeDays : 0) + " / 14"
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
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: root.theme.space(8)
                    DText {
                        theme: root.theme; Layout.fillWidth: true; Layout.topMargin: root.tabletMetrics ? 0 : root.theme.space(8)
                        text: "All activities"; color: root.theme.secondary; font.pixelSize: root.theme.small
                    }
                    DText {
                        id: activityCounts
                        objectName: "overviewActivityCounts"
                        theme: root.theme; Layout.fillWidth: true
                        text: (root.summary ? root.summary.openActivities : 0) + " open · " + (root.summary ? root.summary.doneActivities : 0) + " done"
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
        ColumnLayout {
            visible: root.wide || root.expanded
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.preferredWidth: root.theme.space(440); Layout.alignment: Qt.AlignTop
            spacing: root.theme.space(12)
            EntryCalendar {
                theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                days: root.summary ? root.summary.days : []
                counts: root.summary ? root.summary.days.map(day => day.entries) : []
            }
            DText {
                theme: root.theme; Layout.fillWidth: true
                visible: !root.summary || root.summary.entryCount === 0
                text: "No entries in these 14 days."
                color: root.theme.secondary; font.pixelSize: root.theme.small
            }
        }
        RecentActivities {
            visible: root.wide || root.expanded
            theme: root.theme; summary: root.summary; activitiesById: root.activitiesById; compact: true
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.preferredWidth: root.theme.space(200); Layout.alignment: Qt.AlignTop
            onActivityRequested: id => root.activityRequested(id)
        }
    }
}
