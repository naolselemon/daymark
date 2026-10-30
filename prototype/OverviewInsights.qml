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
    property bool fullyExpanded: false
    readonly property bool wide: width >= theme.space(760)
    signal activityRequested(string id)
    implicitHeight: content.implicitHeight + theme.space(16)
    color: "transparent"
    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: root.theme.border }
    ColumnLayout {
        id: content
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.topMargin: root.theme.space(8)
        spacing: root.theme.space(8)
        DisclosureHeading {
            visible: !root.fullyExpanded
            theme: root.theme; title: qsTr("14-day insights"); Layout.fillWidth: true
            objectName: "overviewInsightsToggle"
            summary: root.summary ? qsTr("%1 entries").arg(root.summary.entryCount) : qsTr("No entries")
            expanded: root.expanded
            onClicked: root.expanded = !root.expanded
        }
        GridLayout {
            objectName: "overviewSummaryMetrics"
            Layout.fillWidth: true; Layout.minimumWidth: 0
            columns: width >= root.theme.space(340) ? 3 : 1
            uniformCellWidths: true
            columnSpacing: root.theme.space(12); rowSpacing: root.theme.space(6)
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                DText { theme: root.theme; objectName: "overviewEntryCount"; text: root.summary ? root.summary.entryCount : 0; font.pixelSize: root.theme.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                DText { theme: root.theme; text: qsTr("entries / 14 days"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
            }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                DText { theme: root.theme; text: (root.summary ? root.summary.activeDays : 0) + " / 14"; font.pixelSize: root.theme.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                DText { theme: root.theme; text: qsTr("days with entries"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
            }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                DText { theme: root.theme; text: qsTr("All activities"); color: root.theme.secondary; font.pixelSize: root.theme.small; Layout.fillWidth: true }
                DText { theme: root.theme; objectName: "overviewActivityCounts"; text: (root.summary ? root.summary.openActivities : 0) + qsTr(" open · ") + (root.summary ? root.summary.doneActivities : 0) + qsTr(" done"); Layout.fillWidth: true; wrapMode: Text.Wrap }
            }
        }
        GridLayout {
            visible: root.expanded || root.fullyExpanded
            Layout.fillWidth: true; Layout.minimumWidth: 0
            columns: root.wide ? 2 : 1
            columnSpacing: root.theme.space(20); rowSpacing: root.theme.space(12)
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.preferredWidth: root.theme.space(460); Layout.alignment: Qt.AlignTop
                spacing: root.theme.space(6)
                EntryCalendar {
                    theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                    days: root.summary ? root.summary.days : []
                    counts: root.summary ? root.summary.days.map(day => day.entries) : []
                }
                DText { theme: root.theme; Layout.fillWidth: true; visible: !root.summary || root.summary.entryCount === 0; text: qsTr("No entries in these 14 days."); color: root.theme.secondary; font.pixelSize: root.theme.small }
            }
            RecentActivities {
                theme: root.theme; summary: root.summary; activitiesById: root.activitiesById; compact: true
                Layout.fillWidth: true; Layout.minimumWidth: 0
                Layout.preferredWidth: root.theme.space(220); Layout.alignment: Qt.AlignTop
                onActivityRequested: id => root.activityRequested(id)
            }
        }
    }
}
