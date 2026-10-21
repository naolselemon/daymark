pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    property bool deletedExpanded: false
    property int trashPage: 0
    readonly property var activityTrash: store.trash.filter(item => item.kind === "activity" || item.kind === "session")
    onActivityTrashChanged: trashPage = Math.min(trashPage, Math.max(0, Math.ceil(activityTrash.length / 20) - 1))
    readonly property var days: {
        if (!visible || store.historyLoading || store.historyError) return [];
        const groups = Object.create(null);
        function group(date) {
            if (!groups[date]) groups[date] = {date: date, sessions: [], completions: []};
            return groups[date];
        }
        workspace.sessionRows(store.historyEntries).forEach(row => group(row.session.date).sessions.push(row));
        store.historyCompletions.forEach(activity => group(activity.completedDate).completions.push(activity));
        return Object.keys(groups).sort().reverse().map(date => groups[date]);
    }
    spacing: theme.space(36)
    DText { theme: root.theme; text: "Searching…"; visible: root.store.historyLoading; Layout.fillWidth: true; color: root.theme.secondary }
    DText { theme: root.theme; text: root.store.historyError; visible: text !== ""; Layout.fillWidth: true; color: root.theme.urgent }
    Repeater {
        model: root.days
        ColumnLayout {
            id: dayGroup
            required property var modelData
            Layout.fillWidth: true; spacing: root.theme.space(16)
            SectionHeading { theme: root.theme; text: Display.day(dayGroup.modelData.date, root.store.today); Layout.fillWidth: true }
            Repeater {
                model: dayGroup.modelData.sessions
                SessionRow { required property var modelData; theme: root.theme; session: modelData.session; activity: modelData.activity; Layout.fillWidth: true; onDetailsRequested: id => root.workspace.selectActivity(id) }
            }
            Repeater {
                model: dayGroup.modelData.completions
                ActivityRow {
                    required property var modelData
                    theme: root.theme; activity: modelData; contextText: "Completed"; Layout.fillWidth: true
                    actionsEnabled: !root.workspace.actionPending
                    onDetailsRequested: id => root.workspace.selectActivity(id)
                    onCompleteRequested: id => root.workspace.completeActivity(id)
                }
            }
        }
    }
    RowLayout {
        visible: !root.store.historyError && (root.store.historyHasMore || root.store.historyOffset > 0); Layout.fillWidth: true
        DButton { theme: root.theme; objectName: "historyPrevious"; text: "Newer"; enabled: root.store.historyOffset > 0 && !root.store.historyLoading; onClicked: root.store.loadPreviousHistory() }
        DText { theme: root.theme; text: "Page " + (Math.floor(root.store.historyOffset / 100) + 1); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; color: root.theme.secondary }
        DButton { theme: root.theme; objectName: "historyNext"; text: "Older"; enabled: !root.store.historyLoading && root.store.historyHasMore; onClicked: root.store.loadMoreHistory() }
    }
    ColumnLayout {
        visible: root.store.loaded && !root.store.historyLoading && !root.store.historyError && root.store.historyTotal === 0
        Layout.fillWidth: true; spacing: root.theme.space(12)
        DText { theme: root.theme; text: root.workspace.query ? "Nothing found just yet." : "Your story starts here."; font.pixelSize: root.theme.title; Layout.fillWidth: true }
        DText { theme: root.theme; text: root.workspace.query ? "Try another word, or clear your search." : "Logged activities and completions will collect here."; color: root.theme.secondary; Layout.fillWidth: true }
        DButton { theme: root.theme; quiet: true; text: "Clear search"; visible: !!root.workspace.query; onClicked: root.workspace.query = "" }
    }
    ColumnLayout {
        Layout.fillWidth: true; visible: root.activityTrash.length > 0
        spacing: root.theme.space(10)
        DButton { theme: root.theme; quiet: true; text: root.deletedExpanded ? "Hide recently deleted" : "Recently deleted · " + root.activityTrash.length; font.pixelSize: root.theme.small; objectName: "recentlyDeleted"; onClicked: root.deletedExpanded = !root.deletedExpanded }
        Repeater {
            model: root.visible && root.deletedExpanded ? root.activityTrash.slice(root.trashPage * 20, (root.trashPage + 1) * 20) : []
            ColumnLayout {
                id: deletedRow
                required property var modelData
                Layout.fillWidth: true
                DText { theme: root.theme; text: deletedRow.modelData.title || "Activity entry"; maximumLineCount: 2; elide: Text.ElideRight; Layout.fillWidth: true }
                Flow {
                    Layout.fillWidth: true; spacing: root.theme.gap
                    DButton { theme: root.theme; text: "Restore"; objectName: "trashUndo-" + deletedRow.modelData.id; enabled: !root.workspace.undoSaving; onClicked: root.workspace.restoreDeleted(deletedRow.modelData.id) }
                    DButton { theme: root.theme; quiet: true; text: "Delete permanently"; objectName: "trashPurge-" + deletedRow.modelData.id; onClicked: root.workspace.requestDelete("purge", deletedRow.modelData.id, 0, deletedRow.modelData.title || "Activity entry") }
                }
            }
        }
        RowLayout {
            visible: root.deletedExpanded && root.activityTrash.length > 20; Layout.fillWidth: true
            DButton { theme: root.theme; text: "Previous"; enabled: root.trashPage > 0; onClicked: root.trashPage-- }
            DText { theme: root.theme; text: "Page " + (root.trashPage + 1); Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Next"; enabled: (root.trashPage + 1) * 20 < root.activityTrash.length; onClicked: root.trashPage++ }
        }
    }
}
