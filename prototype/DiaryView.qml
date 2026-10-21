pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Item {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    readonly property bool wide: width >= theme.space(940)
    readonly property bool calendarOpen: pageDate.calendarOpen
    readonly property string day: workspace.diaryDate
    readonly property var noteError: store.noteErrors[day]
    readonly property bool conflict: !!noteError && noteError.code === "conflict"
    readonly property var deletedNotes: store.trash.filter(item => item.kind === "note")
    property bool libraryOpen: false
    property bool deletedExpanded: false
    property int trashPage: 0
    property bool syncingEditor: false
    property string editingDay: ""
    clip: true

    function focusEditor() {
        libraryOpen = false;
        Qt.callLater(() => {
            dailyNote.forceActiveFocus(Qt.ShortcutFocusReason);
            revealCursor();
        });
    }
    function focusSearch() {
        libraryOpen = true;
        Qt.callLater(() => diarySearch.forceActiveFocus(Qt.ShortcutFocusReason));
    }
    function syncEditor() {
        if (!dailyNote) return;
        syncingEditor = true;
        editingDay = day;
        const body = store.noteFor(day);
        if (dailyNote.text !== body) dailyNote.text = body;
        syncingEditor = false;
    }
    function openPage(date) {
        store.flushNotes();
        workspace.openDiary(date);
        focusEditor();
    }
    function changeDay(date) {
        store.flushNotes();
        workspace.setDiaryDate(date);
    }
    function revealCursor() {
        if (!dailyNote || !dailyNote.activeFocus || !writingPane.visible) return;
        const cursor = dailyNote.cursorRectangle;
        const point = dailyNote.mapToItem(writingContent, cursor.x, cursor.y);
        const margin = theme.space(24);
        let target = writingFlick.contentY;
        if (point.y < target + margin) target = point.y - margin;
        else if (point.y + cursor.height > target + writingFlick.height - margin)
            target = point.y + cursor.height - writingFlick.height + margin;
        writingFlick.contentY = Math.max(0, Math.min(Math.max(0, writingFlick.contentHeight - writingFlick.height), target));
    }
    onDayChanged: {
        syncEditor();
        if (writingFlick) writingFlick.contentY = 0;
        if (pageDate) pageDate.text = day;
    }
    onDeletedNotesChanged: trashPage = Math.min(trashPage, Math.max(0, Math.ceil(deletedNotes.length / 20) - 1))
    Component.onCompleted: syncEditor()
    Connections {
        target: root.store
        function onNoteDraftsChanged() { root.syncEditor(); }
        function onDayNotesChanged() { root.syncEditor(); }
    }

    RowLayout {
        anchors.fill: parent
        spacing: root.wide ? root.theme.space(28) : 0

        Rectangle {
            id: libraryPane
            visible: root.wide || root.libraryOpen
            Layout.fillHeight: true
            Layout.fillWidth: !root.wide
            Layout.preferredWidth: root.wide ? root.theme.space(290) : -1
            Layout.minimumWidth: 0
            color: root.theme.surface
            radius: root.theme.radius

            ScrollView {
                id: libraryScroll
                anchors.fill: parent
                anchors.margins: root.theme.space(16)
                contentWidth: availableWidth
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    width: libraryScroll.availableWidth
                    spacing: root.theme.space(16)
                    DText {
                        theme: root.theme; text: "Your pages"; font.pixelSize: root.theme.heading
                        Layout.fillWidth: true
                    }
                    DText {
                        theme: root.theme; text: "A little space for every day."; color: root.theme.secondary
                        font.pixelSize: root.theme.small; Layout.fillWidth: true
                    }
                    Flow {
                        visible: !root.wide
                        Layout.fillWidth: true; spacing: root.theme.gap
                        DButton {
                            theme: root.theme; quiet: true; text: "Back to writing"
                            objectName: "diaryBackToWriting"; onClicked: root.focusEditor()
                        }
                        DButton {
                            theme: root.theme; quiet: true; text: "Lock diary"
                            objectName: "diaryLibraryLock"; onClicked: root.workspace.lockDiary()
                        }
                    }
                    DField {
                        id: diarySearch
                        theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                        objectName: "diarySearch"; placeholderText: "Search your pages"
                        Accessible.name: "Search diary pages"
                        text: root.workspace.diaryQuery
                        onTextEdited: root.workspace.diaryQuery = text
                    }
                    DButton {
                        theme: root.theme; quiet: true; text: "Clear search"; visible: !!root.workspace.diaryQuery
                        onClicked: root.workspace.diaryQuery = ""
                    }
                    DText {
                        theme: root.theme; text: "Finding your pages…"; visible: root.store.historyLoading
                        color: root.theme.secondary; Layout.fillWidth: true
                    }
                    DText {
                        theme: root.theme; text: root.store.historyError; visible: text !== ""
                        color: root.theme.urgent; Layout.fillWidth: true
                    }
                    ColumnLayout {
                        visible: !root.store.historyLoading && !root.store.historyError && root.store.historyNotes.length === 0
                        Layout.fillWidth: true; spacing: root.theme.space(8)
                        DText {
                            theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.heading
                            text: root.workspace.diaryQuery ? "No matching pages" : "Your first page awaits"
                        }
                        DText {
                            theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                            text: root.workspace.diaryQuery ? "Try another word or a date, such as " + root.store.today.slice(0, 7) + "." : "Choose a day and start writing. Saved pages will collect here."
                        }
                        DButton { theme: root.theme; quiet: true; text: "Start writing"; visible: !root.workspace.diaryQuery; onClicked: root.focusEditor() }
                    }
                    Repeater {
                        model: root.store.historyLoading || root.store.historyError ? [] : root.store.historyNotes
                        DButton {
                            id: pageCard
                            required property var modelData
                            theme: root.theme; quiet: true; selected: modelData.date === root.day
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            objectName: "diaryOpen-" + modelData.date
                            padding: root.theme.space(14)
                            // The content wraps to the assigned width; do not feed
                            // that width back into the button's implicit size.
                            implicitWidth: root.theme.space(220)
                            implicitHeight: pageSummary.implicitHeight + topPadding + bottomPadding
                            Accessible.name: "Diary, " + Display.day(modelData.date) + (selected ? ", selected" : ", open to read or edit")
                            contentItem: Column {
                                id: pageSummary
                                spacing: root.theme.space(8)
                                DText {
                                    theme: root.theme; width: parent.width
                                    text: Qt.formatDate(new Date(pageCard.modelData.date + "T12:00:00"), "d MMMM yyyy")
                                    font.bold: pageCard.selected
                                    color: pageCard.selected ? root.theme.accent : root.theme.foreground
                                }
                                DText {
                                    theme: root.theme; width: parent.width
                                    text: pageCard.modelData.body.trim() || "An empty page"
                                    font.pixelSize: root.theme.small; color: root.theme.secondary
                                    maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap
                                }
                            }
                            onClicked: root.openPage(modelData.date)
                        }
                    }
                    ColumnLayout {
                        visible: !root.store.historyError && (root.store.historyHasMore || root.store.historyOffset > 0)
                        Layout.fillWidth: true; spacing: root.theme.space(6)
                        DText {
                            theme: root.theme; text: "Page " + (Math.floor(root.store.historyOffset / 100) + 1)
                            font.pixelSize: root.theme.small; color: root.theme.secondary; Layout.fillWidth: true
                        }
                        Flow {
                            Layout.fillWidth: true; spacing: root.theme.gap
                            DButton { theme: root.theme; text: "Newer"; objectName: "diaryPrevious"; enabled: root.store.historyOffset > 0 && !root.store.historyLoading; onClicked: root.store.loadPreviousHistory() }
                            DButton { theme: root.theme; text: "Older"; objectName: "diaryNext"; enabled: root.store.historyHasMore && !root.store.historyLoading; onClicked: root.store.loadMoreHistory() }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                    DButton {
                        theme: root.theme; quiet: true; Layout.fillWidth: true; Layout.minimumWidth: 0
                        font.pixelSize: root.theme.small
                        text: (root.deletedExpanded ? "Hide deleted pages" : "Recently deleted") + " · " + root.deletedNotes.length
                        objectName: "diaryRecentlyDeleted"
                        onClicked: root.deletedExpanded = !root.deletedExpanded
                    }
                    DText {
                        theme: root.theme; text: "No deleted diary pages."; color: root.theme.secondary
                        visible: root.deletedExpanded && root.deletedNotes.length === 0; Layout.fillWidth: true
                    }
                    Repeater {
                        model: root.deletedExpanded ? root.deletedNotes.slice(root.trashPage * 20, (root.trashPage + 1) * 20) : []
                        ColumnLayout {
                            id: deletedPage
                            required property var modelData
                            Layout.fillWidth: true; spacing: root.theme.space(8)
                            DText {
                                theme: root.theme; text: deletedPage.modelData.title || "Diary page"
                                maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap; Layout.fillWidth: true
                            }
                            Flow {
                                Layout.fillWidth: true; spacing: root.theme.gap
                                DButton {
                                    theme: root.theme; text: "Restore"; objectName: "trashUndo-" + deletedPage.modelData.id
                                    onClicked: root.workspace.restoreDeleted(deletedPage.modelData.id)
                                }
                                DButton {
                                    theme: root.theme; quiet: true; text: "Delete permanently"; font.pixelSize: root.theme.small
                                    objectName: "trashPurge-" + deletedPage.modelData.id
                                    onClicked: root.workspace.requestDelete("purge", deletedPage.modelData.id, 0, deletedPage.modelData.title || "Diary page")
                                }
                            }
                        }
                    }
                    Flow {
                        visible: root.deletedExpanded && root.deletedNotes.length > 20
                        Layout.fillWidth: true; spacing: root.theme.gap
                        DButton { theme: root.theme; text: "Previous"; enabled: root.trashPage > 0; onClicked: root.trashPage-- }
                        DButton { theme: root.theme; text: "Next"; enabled: (root.trashPage + 1) * 20 < root.deletedNotes.length; onClicked: root.trashPage++ }
                    }
                }
            }
        }

        Item {
            id: writingPane
            visible: root.wide || !root.libraryOpen
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
            ScrollView {
                id: writingScroll
                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                Flickable {
                    id: writingFlick
                    contentWidth: width
                    contentHeight: writingContent.height
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick
                    ColumnLayout {
                        id: writingContent
                        width: Math.max(0, Math.min(writingFlick.width - root.theme.space(24), root.theme.space(850)))
                        x: (writingFlick.width - width) / 2
                        spacing: root.theme.space(20)
                        Item { Layout.fillWidth: true; implicitHeight: root.theme.space(4) }
                        Flow {
                            Layout.fillWidth: true; spacing: root.theme.gap
                            DButton {
                                theme: root.theme; quiet: true; text: "All pages"; visible: !root.wide
                                objectName: "diaryBrowse"; shortcutHint: "Ctrl+Shift+J"; onClicked: root.focusSearch()
                            }
                            DateField {
                                id: pageDate
                                theme: root.theme; today: root.store.today; text: root.day
                                fieldName: "diaryDate"; caption: "Choose date"
                                onTextEdited: root.changeDay(text)
                            }
                            DButton { theme: root.theme; quiet: true; text: "‹"; Accessible.name: "Previous diary day"; objectName: "diaryPreviousDay"; onClicked: root.changeDay(root.workspace.offsetDay(root.day, -1)) }
                            DButton { theme: root.theme; quiet: true; text: "›"; Accessible.name: "Next diary day"; objectName: "diaryNextDay"; onClicked: root.changeDay(root.workspace.offsetDay(root.day, 1)) }
                            DButton { theme: root.theme; quiet: true; text: "Today"; objectName: "diaryToday"; enabled: root.day !== root.store.today; onClicked: root.changeDay(root.store.today) }
                            DButton { theme: root.theme; quiet: true; text: "Lock diary"; objectName: "diaryLock"; onClicked: root.workspace.lockDiary() }
                        }
                        ColumnLayout {
                            id: pageHeading
                            Layout.fillWidth: true; spacing: root.theme.space(8)
                            DText {
                                theme: root.theme; text: Qt.formatDate(new Date(root.day + "T12:00:00"), "dddd")
                                color: root.theme.accent; font.pixelSize: root.theme.small; Layout.fillWidth: true
                            }
                            DText {
                                theme: root.theme; text: Qt.formatDate(new Date(root.day + "T12:00:00"), "d MMMM yyyy")
                                font.pixelSize: root.theme.pageTitle; Layout.fillWidth: true; wrapMode: Text.Wrap
                            }
                            DText {
                                theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                                text: root.store.noteStatus[root.day] || (root.store.dayNotes[root.day] !== undefined ? "Saved" : "A fresh page · autosaves as you write")
                                color: root.noteError ? root.theme.urgent : root.theme.secondary
                                objectName: "diarySaveStatus"
                                Accessible.role: Accessible.StaticText
                            }
                        }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                        ColumnLayout {
                            visible: !!root.noteError; Layout.fillWidth: true; spacing: root.theme.space(12)
                            DText {
                                theme: root.theme; Layout.fillWidth: true; wrapMode: Text.Wrap
                                text: root.noteError ? root.noteError.message : ""; color: root.theme.urgent
                            }
                            Flow {
                                Layout.fillWidth: true; spacing: root.theme.gap; visible: !root.conflict
                                DButton { theme: root.theme; text: "Retry save"; objectName: "retryNote"; onClicked: root.store.retryNote(root.day, false) }
                                DButton { theme: root.theme; text: "Discard draft"; objectName: "discardNote"; onClicked: root.store.discardNote(root.day) }
                            }
                            DText {
                                theme: root.theme; Layout.fillWidth: true; visible: root.conflict
                                text: "Another window saved a different page. Your draft is still below."; color: root.theme.secondary
                            }
                            ScrollView {
                                id: conflictScroll
                                visible: root.conflict; Layout.fillWidth: true
                                Layout.preferredHeight: Math.min(root.theme.space(190), savedVersion.implicitHeight)
                                contentWidth: availableWidth; clip: true
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                DArea {
                                    id: savedVersion
                                    theme: root.theme; width: conflictScroll.availableWidth; readOnly: true
                                    Accessible.name: "Saved version from another window"
                                    text: root.noteError && root.noteError.currentNote ? root.noteError.currentNote.body : ""
                                    wrapMode: TextEdit.Wrap
                                }
                            }
                            Flow {
                                Layout.fillWidth: true; spacing: root.theme.gap; visible: root.conflict
                                DButton { theme: root.theme; text: "Keep my version"; objectName: "overwriteNote"; onClicked: root.store.retryNote(root.day, true) }
                                DButton { theme: root.theme; text: "Use saved version"; objectName: "useSavedNote"; onClicked: root.store.useSavedNote(root.day) }
                            }
                        }
                        DArea {
                            id: dailyNote
                            theme: root.theme; framed: false; objectName: "dailyNote"
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            Layout.preferredHeight: Math.max(implicitHeight, writingFlick.height - pageHeading.height - root.theme.space(230), root.theme.space(260))
                            padding: root.theme.space(8)
                            font.pixelSize: Math.max(root.theme.body, root.theme.space(18))
                            placeholderText: "What would you like to remember?"
                            Accessible.name: "Diary page, " + Display.day(root.day)
                            enabled: root.store.loaded
                            background: Rectangle {
                                color: "transparent"
                                Rectangle {
                                    width: Math.max(1, root.theme.strokeWidth("focus")); height: parent.height
                                    color: root.theme.accent; visible: dailyNote.activeFocus; opacity: 0.45
                                }
                            }
                            onTextChanged: {
                                if (!root.syncingEditor && root.editingDay && text !== root.store.noteFor(root.editingDay))
                                    root.store.editNote(root.editingDay, text);
                            }
                            onCursorRectangleChanged: if (activeFocus) Qt.callLater(root.revealCursor)
                            onActiveFocusChanged: {
                                if (activeFocus) Qt.callLater(root.revealCursor);
                                else root.store.flushNotes();
                            }
                        }
                        Flow {
                            Layout.fillWidth: true; spacing: root.theme.gap
                            DButton {
                                theme: root.theme; quiet: true; font.pixelSize: root.theme.small
                                text: "Delete page"; objectName: "dailyNoteDelete"
                                visible: root.store.records.dayNotes[root.day] !== undefined
                                enabled: !root.store.dirtyNotes[root.day]
                                onClicked: root.workspace.requestDelete("note", root.day, root.store.records.dayNotes[root.day].revision, "Diary page · " + Display.day(root.day, root.store.today))
                            }
                        }
                        Item { Layout.fillWidth: true; implicitHeight: root.theme.space(24) }
                    }
                }
            }
        }
    }
}
