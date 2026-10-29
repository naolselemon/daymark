pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    property var calendarController: null
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    readonly property var plans: visible ? store.planned(store.date) : []
    readonly property var entries: visible ? store.timeline(store.date) : []
    readonly property var completions: visible ? store.completionOnly(store.date) : []
    readonly property var earlierPlans: visible ? store.overdue(store.date) : []
    property bool earlierExpanded: false
    spacing: theme.space(24)

    PinnedActivities { workspace: root.workspace; Layout.fillWidth: true }
    GridLayout {
        objectName: "todayQuietColumns"
        Layout.fillWidth: true; Layout.minimumWidth: 0
        columns: width >= root.theme.space(760) ? 2 : 1
        uniformCellWidths: true
        columnSpacing: root.theme.space(56); rowSpacing: root.theme.space(32)
        Item {
            objectName: "todayPlannedColumn"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
            Layout.preferredWidth: 1
            implicitHeight: plannedContent.implicitHeight
            ColumnLayout {
                id: plannedContent
                anchors.fill: parent
                spacing: root.theme.space(16)
                RowLayout {
                    Layout.fillWidth: true; spacing: root.theme.space(12)
                    SectionHeading {
                        theme: root.theme; text: "On your list"
                    }
                    DText { theme: root.theme; objectName: "todayPlanCount"; text: root.plans.length; color: root.theme.secondary; font.pixelSize: root.theme.small }
                    Item { Layout.fillWidth: true }
                    DButton { theme: root.theme; text: "Add plan"; iconName: "add"; quiet: true; shortcutHint: "Ctrl+N"; objectName: "todayAddPlan"; onClicked: root.workspace.openComposer("plan", "") }
                }
                Repeater {
                    model: root.plans.slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50)
                    ActivityRow {
                        required property var modelData
                        theme: root.theme; activity: modelData; Layout.fillWidth: true; showNavigation: true
                        actionsEnabled: !root.workspace.actionPending && !root.workspace.countdownController.logPending
                        onDetailsRequested: id => root.workspace.selectActivity(id)
                        onCompleteRequested: id => root.workspace.completeActivity(id)
                    }
                }
                DText { theme: root.theme; text: "An open day. Add one thing you'd like to do."; color: root.theme.secondary; visible: root.plans.length === 0; Layout.fillWidth: true }
                Item { Layout.fillHeight: true; Layout.preferredHeight: 0 }
                DButton {
                    theme: root.theme; quiet: true; font.pixelSize: root.theme.small; objectName: "earlierPlansToggle"
                    Layout.fillWidth: false; Layout.minimumWidth: 0
                    visible: root.earlierPlans.length > 0 || root.workspace.movedPlans.length > 0
                    text: root.earlierExpanded ? "Hide earlier plans" : "Earlier plans · " + (root.earlierPlans.length + root.workspace.movedPlans.length)
                    iconName: root.earlierExpanded ? "collapse" : "expand"
                    iconOnly: false
                    onClicked: root.earlierExpanded = !root.earlierExpanded
                }
                Repeater {
                    model: root.earlierExpanded ? root.earlierPlans.slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50) : []
                    ActivityRow {
                        required property var modelData
                        theme: root.theme; activity: modelData; Layout.fillWidth: true; showNavigation: true
                        contextText: Display.day(modelData.plannedFor, root.store.today)
                        actionsEnabled: !root.workspace.actionPending && !root.workspace.countdownController.logPending
                        onDetailsRequested: id => root.workspace.selectActivity(id)
                        onCompleteRequested: id => root.workspace.completeActivity(id)
                    }
                }
                Repeater {
                    model: root.visible && root.earlierExpanded ? root.workspace.movedPlans.slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50) : []
                    DText { required property var modelData; theme: root.theme; text: root.store.activity(modelData.activityId).title + " · moved to " + Display.day(modelData.to, root.store.today); color: root.theme.secondary; Layout.fillWidth: true }
                }
            }
        }
        Item {
            objectName: "todayEntriesColumn"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
            Layout.preferredWidth: 1
            implicitHeight: recordedContent.implicitHeight
            ColumnLayout {
                id: recordedContent
                anchors.fill: parent
                spacing: root.theme.space(16)
                RowLayout {
                    Layout.fillWidth: true; spacing: root.theme.space(12)
                    SectionHeading {
                        theme: root.theme; text: "Entries"
                    }
                    DText { theme: root.theme; objectName: "todayEntryCount"; text: root.entries.length; color: root.theme.secondary; font.pixelSize: root.theme.small }
                    Item { Layout.fillWidth: true }
                    DButton { theme: root.theme; text: "Log activity"; iconName: "log"; quiet: true; shortcutHint: "Ctrl+L"; objectName: "todayLogWork"; onClicked: root.workspace.openComposer("log", "") }
                }
                Repeater {
                    model: root.workspace.sessionRows(root.entries.slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50))
                    SessionRow { required property var modelData; theme: root.theme; session: modelData.session; activity: modelData.activity; Layout.fillWidth: true; showIcon: true; onDetailsRequested: id => root.workspace.selectActivity(id) }
                }
                SectionHeading {
                    theme: root.theme; text: "Completed · " + root.completions.length
                    visible: root.completions.length > 0; Layout.fillWidth: true
                }
                Repeater {
                    model: root.completions.slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50)
                    ActivityRow {
                        required property var modelData
                        theme: root.theme; activity: modelData; contextText: "Completed"; Layout.fillWidth: true
                        actionsEnabled: !root.workspace.actionPending && !root.workspace.countdownController.logPending
                        onDetailsRequested: id => root.workspace.selectActivity(id)
                        onCompleteRequested: id => root.workspace.completeActivity(id)
                    }
                }
                DText { theme: root.theme; text: "Small things count. Record something you did."; color: root.theme.secondary; visible: root.entries.length === 0 && root.completions.length === 0; Layout.fillWidth: true }
                Item { Layout.fillHeight: true; Layout.preferredHeight: 0 }
            }
        }
    }
    RowLayout {
        visible: root.workspace.todayPageCount > 1 || root.workspace.todayPage > 0; Layout.fillWidth: true
        DButton { theme: root.theme; objectName: "todayPreviousRecords"; text: "Previous"; iconName: "previous"; enabled: root.workspace.todayPage > 0; onClicked: root.workspace.todayPage-- }
        DText { theme: root.theme; text: "Page " + (root.workspace.todayPage + 1); color: root.theme.secondary; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
        DButton { theme: root.theme; objectName: "todayNextRecords"; text: "Next"; iconName: "next"; enabled: root.workspace.todayPage + 1 < root.workspace.todayPageCount; onClicked: root.workspace.todayPage++ }
    }
    CalendarEventList {
        theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
        visible: root.calendarController !== null && root.calendarController.configured
        events: root.calendarController ? root.calendarController.events : []
        filterDate: root.store.date
        windowStart: root.calendarController ? root.calendarController.info.windowStart : ""
        windowEnd: root.calendarController ? root.calendarController.info.windowEnd : ""
        windowLabel: root.calendarController ? root.calendarController.windowLabel : ""
        calendarName: root.calendarController ? root.calendarController.info.name : ""
        statusText: root.calendarController ? root.calendarController.statusText : ""
    }
}
