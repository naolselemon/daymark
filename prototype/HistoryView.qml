pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    readonly property bool diary: workspace.historySection === "diary"
    property bool deletedExpanded: false
    property int trashPage: 0
    readonly property var days: {
        if (!visible || diary || store.historyLoading || store.historyError) return [];
        const groups = Object.create(null);
        function group(date) {
            if (!groups[date]) groups[date] = {date: date, sessions: [], completions: [], notes: []};
            return groups[date];
        }
        workspace.sessionRows(store.historyEntries).forEach(row => group(row.session.date).sessions.push(row));
        store.historyCompletions.forEach(activity => group(activity.completedDate).completions.push(activity));
        store.historyNotes.forEach(note => group(note.date).notes.push(note));
        return Object.keys(groups).sort().reverse().map(date => groups[date]);
    }
    spacing: theme.space(28)
    Connections { target: root.store; function onTrashChanged() { root.trashPage = Math.min(root.trashPage, Math.max(0, Math.ceil(root.store.trash.length / 20) - 1)); } }
    Flow {
        Layout.fillWidth: true; spacing: root.theme.gap
        DButton { theme: root.theme; text: "All entries"; objectName: "historyAll"; selected: !root.diary; onClicked: root.workspace.setHistorySection("all") }
        DButton { theme: root.theme; text: "Diary"; objectName: "historyDiary"; selected: root.diary; onClicked: root.workspace.setHistorySection("diary") }
    }
    DText { theme: root.theme; text: "Searching…"; visible: root.store.historyLoading; Layout.fillWidth: true; color: root.theme.secondary }
    DText { theme: root.theme; text: root.store.historyError; visible: text !== ""; Layout.fillWidth: true; color: root.theme.urgent }
    DiaryView { workspace: root.workspace; visible: root.diary; Layout.fillWidth: true }
    Repeater {
        model: root.days
        ColumnLayout {
            id: dayGroup
            required property var modelData
            Layout.fillWidth: true; spacing: root.theme.space(12)
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
            Repeater {
                model: dayGroup.modelData.notes
                DButton {
                    id: noteRow
                    required property var modelData
                    theme: root.theme; quiet: true; Layout.fillWidth: true
                    objectName: "historyNoteOpen-" + modelData.date
                    implicitHeight: noteContent.implicitHeight + topPadding + bottomPadding
                    padding: root.theme.space(18)
                    Accessible.name: "Daily note, " + Display.day(modelData.date, root.store.today) + ", open to read or edit"
                    background: Rectangle { color: root.theme.accentSurface; radius: root.theme.radius; border.color: root.theme.accent; border.width: noteRow.activeFocus ? 1 : 0 }
                    contentItem: Column {
                        id: noteContent; spacing: root.theme.space(8)
                        DText { theme: root.theme; text: "Daily note"; font.pixelSize: root.theme.small; color: root.theme.accent; width: parent.width }
                        DText { theme: root.theme; text: noteRow.modelData.body.trim() || "An empty page, ready when you are."; maximumLineCount: 3; elide: Text.ElideRight; width: parent.width }
                    }
                    onClicked: root.workspace.openDiary(modelData.date)
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
        DText { theme: root.theme; text: root.workspace.query ? "Nothing found just yet." : root.diary ? "A place for your days." : "Your story starts here."; font.pixelSize: root.theme.title; Layout.fillWidth: true }
        DText { theme: root.theme; text: root.workspace.query ? (root.diary ? "Try a word from your diary or a date, such as " + root.store.today.slice(0, 7) + "." : "Try another word, or clear your search.") : root.diary ? "Write a daily diary from Today. Every saved page will be here, ready to revisit." : "Activities and daily notes will collect here."; color: root.theme.secondary; Layout.fillWidth: true }
        DButton { theme: root.theme; quiet: true; text: "Clear search"; visible: !!root.workspace.query; onClicked: root.workspace.query = "" }
    }
    ColumnLayout {
        Layout.fillWidth: true; visible: root.store.trash.length > 0
        spacing: root.theme.space(10)
        DButton { theme: root.theme; quiet: true; text: root.deletedExpanded ? "Hide recently deleted" : "Recently deleted · " + root.store.trash.length; font.pixelSize: root.theme.small; objectName: "recentlyDeleted"; onClicked: root.deletedExpanded = !root.deletedExpanded }
        Repeater {
            model: root.visible && root.deletedExpanded ? root.store.trash.slice(root.trashPage * 20, (root.trashPage + 1) * 20) : []
            ColumnLayout {
                id: deletedRow
                required property var modelData
                Layout.fillWidth: true
                DText { theme: root.theme; text: deletedRow.modelData.title || "Journal entry"; maximumLineCount: 2; elide: Text.ElideRight; Layout.fillWidth: true }
                Flow {
                    Layout.fillWidth: true; spacing: root.theme.gap
                    DButton { theme: root.theme; text: "Restore"; objectName: "trashUndo-" + deletedRow.modelData.id; enabled: !root.workspace.undoSaving; onClicked: root.workspace.restoreDeleted(deletedRow.modelData.id) }
                    DButton { theme: root.theme; quiet: true; text: "Delete permanently"; objectName: "trashPurge-" + deletedRow.modelData.id; onClicked: root.workspace.requestDelete("purge", deletedRow.modelData.id, 0, deletedRow.modelData.title || "Journal entry") }
                }
            }
        }
        RowLayout {
            visible: root.deletedExpanded && root.store.trash.length > 20; Layout.fillWidth: true
            DButton { theme: root.theme; text: "Previous"; enabled: root.trashPage > 0; onClicked: root.trashPage-- }
            DText { theme: root.theme; text: "Page " + (root.trashPage + 1); Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Next"; enabled: (root.trashPage + 1) * 20 < root.store.trash.length; onClicked: root.trashPage++ }
        }
    }
}
