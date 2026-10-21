pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    property bool earlierExpanded: false
    spacing: theme.space(28)
    PinnedActivities { workspace: root.workspace; Layout.fillWidth: true }
    ColumnLayout {
        Layout.fillWidth: true; spacing: root.theme.space(10)
        SectionHeading { theme: root.theme; text: "On your list"; Layout.fillWidth: true }
        Repeater {
            model: root.visible ? root.store.planned(root.store.date).slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50) : []
            ActivityRow {
                required property var modelData
                theme: root.theme; activity: modelData; Layout.fillWidth: true
                actionsEnabled: !root.workspace.actionPending
                onDetailsRequested: id => root.workspace.selectActivity(id)
                onCompleteRequested: id => root.workspace.completeActivity(id)
            }
        }
        DText { theme: root.theme; text: "An open day. Add one thing you'd like to do."; color: root.theme.secondary; visible: root.store.planned(root.store.date).length === 0; Layout.fillWidth: true }
        DButton {
            theme: root.theme; quiet: true; font.pixelSize: root.theme.small; objectName: "earlierPlansToggle"
            visible: root.store.overdue(root.store.date).length > 0 || root.workspace.movedPlans.length > 0
            text: root.earlierExpanded ? "Hide earlier plans" : "Earlier plans · " + (root.store.overdue(root.store.date).length + root.workspace.movedPlans.length)
            onClicked: root.earlierExpanded = !root.earlierExpanded
        }
        Repeater {
            model: root.visible && root.earlierExpanded ? root.store.overdue(root.store.date).slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50) : []
            ActivityRow {
                required property var modelData
                theme: root.theme; activity: modelData; Layout.fillWidth: true
                contextText: Display.day(modelData.plannedFor, root.store.today)
                actionsEnabled: !root.workspace.actionPending
                onDetailsRequested: id => root.workspace.selectActivity(id)
                onCompleteRequested: id => root.workspace.completeActivity(id)
            }
        }
        Repeater {
            model: root.visible && root.earlierExpanded ? root.workspace.movedPlans.slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50) : []
            DText { required property var modelData; theme: root.theme; text: root.store.activity(modelData.activityId).title + " · moved to " + Display.day(modelData.to, root.store.today); color: root.theme.secondary; Layout.fillWidth: true }
        }
    }
    ColumnLayout {
        Layout.fillWidth: true; spacing: root.theme.space(10)
        RowLayout {
            Layout.fillWidth: true
            SectionHeading { theme: root.theme; text: "What happened"; Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Log activity"; quiet: true; shortcutHint: "Ctrl+L"; objectName: "todayLogWork"; onClicked: root.workspace.openComposer("log", "") }
        }
        Repeater {
            model: root.visible ? root.workspace.sessionRows(root.store.timeline(root.store.date).slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50)) : []
            SessionRow { required property var modelData; theme: root.theme; session: modelData.session; activity: modelData.activity; Layout.fillWidth: true; onDetailsRequested: id => root.workspace.selectActivity(id) }
        }
        Repeater {
            model: root.visible ? root.store.completionOnly(root.store.date).slice(root.workspace.todayPage * 50, (root.workspace.todayPage + 1) * 50) : []
            ActivityRow {
                required property var modelData
                theme: root.theme; activity: modelData; contextText: "Completed"; Layout.fillWidth: true
                actionsEnabled: !root.workspace.actionPending
                onDetailsRequested: id => root.workspace.selectActivity(id)
                onCompleteRequested: id => root.workspace.completeActivity(id)
            }
        }
        DText { theme: root.theme; text: "Small things count. Record something you did."; color: root.theme.secondary; visible: root.store.timeline(root.store.date).length === 0 && root.store.completionOnly(root.store.date).length === 0; Layout.fillWidth: true }
    }
    RowLayout {
        visible: root.workspace.todayPageCount > 1 || root.workspace.todayPage > 0; Layout.fillWidth: true
        DButton { theme: root.theme; objectName: "todayPreviousRecords"; text: "Previous"; enabled: root.workspace.todayPage > 0; onClicked: root.workspace.todayPage-- }
        DText { theme: root.theme; text: "Page " + (root.workspace.todayPage + 1); color: root.theme.secondary; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
        DButton { theme: root.theme; objectName: "todayNextRecords"; text: "Next"; enabled: root.workspace.todayPage + 1 < root.workspace.todayPageCount; onClicked: root.workspace.todayPage++ }
    }
    DButton {
        theme: root.theme; quiet: true; text: "Open diary"; shortcutHint: "Ctrl+J"; objectName: "todayOpenDiary"
        onClicked: root.workspace.openDiary(root.store.today)
    }
}
