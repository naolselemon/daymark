pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Rectangle {
    id: root
    required property var theme
    required property var store
    required property var diaryAuth
    property string profileLabel: "Isolated profile"
    property bool demoMode: false
    property bool temporaryProfile: false
    property alias composer: composerSheet
    property string page: "Today"
    property string selectedId: ""
    property string query: ""
    property string diaryDate: store.today
    property string diaryQuery: ""
    property bool diaryUnlocked: false
    property bool diarySearchRequested: false
    property var diaryAction: null
    readonly property bool diaryAuthenticating: unlockSheet.opened
    property string feedback: ""
    property string closeFeedback: ""
    property string undoTrashId: ""
    property bool undoSaving: false
    property bool actionPending: false
    property var pendingNavigation: null
    property var returnFocus: null
    property int todayPage: 0
    readonly property bool narrow: width < theme.space(800)
    readonly property bool wideInsights: page !== "Diary" && width >= theme.space(1320)
    readonly property bool calendarOpen: dayPicker.calendarOpen || (detail.visible && detail.calendarOpen)
        || (diaryLoader.item && diaryLoader.item.calendarOpen)
    readonly property bool modalOpen: safetySheet.opened || sessionSheet.opened || deleteSheet.opened || shortcutsSheet.opened || unlockSheet.opened
    readonly property bool shortcutsAvailable: store.loaded && !modalOpen && !calendarOpen && !composerSheet.opened && !confirmSheet.opened
    readonly property var pinnedActivities: store.activities.filter(activity => activity.pinned)
    readonly property var movedPlans: store.events.filter(e => e.action === "reschedule" && e.from === store.date && store.activity(e.activityId))
    readonly property int todayPageCount: Math.max(1, Math.ceil(Math.max(store.planned(store.date).length,
        store.overdue(store.date).length, store.timeline(store.date).length, store.completionOnly(store.date).length, movedPlans.length) / 50))
    onTodayPageCountChanged: todayPage = Math.min(todayPage, todayPageCount - 1)
    signal closeRequested()
    color: theme.background
    objectName: "workspace"

    function dayLabel(day) { return Qt.formatDate(new Date(day + "T12:00:00"), "dddd, d MMMM"); }
    function offsetDay(day, delta) {
        const value = new Date(day + "T12:00:00"); value.setDate(value.getDate() + delta);
        return Qt.formatDate(value, "yyyy-MM-dd");
    }
    function guardNavigation(action) {
        if (modalOpen || calendarOpen) return false;
        if (detail.saving || composerSheet.saving) { feedback = "Finishing your save…"; return false; }
        if (detail.dirty || composerSheet.dirty) {
            pendingNavigation = action; confirmSheet.open(); return false;
        }
        action(); return true;
    }
    function navigate(target) {
        store.flushNotes();
        return guardNavigation(() => { page = target; selectedId = ""; feedback = ""; mainScroll.contentItem.contentY = 0; });
    }
    function setDiaryDate(day) {
        if (!store.validDate(day, false)) return;
        store.flushNotes();
        diaryDate = day;
    }
    function focusDiary() {
        Qt.callLater(() => {
            if (!diaryLoader.item || !diaryUnlocked) return;
            if (diarySearchRequested) diaryLoader.item.focusSearch();
            else diaryLoader.item.focusEditor();
        });
    }
    function authorizeDiary(action, purpose = "Unlock your diary") {
        if (diaryUnlocked) { action(); return true; }
        if (unlockSheet.opened) return false;
        diaryAction = action;
        unlockSheet.begin(purpose);
        return false;
    }
    function cancelDiaryAuthentication() {
        diaryAction = null;
        if (diaryAuth) diaryAuth.cancel();
    }
    function lockDiary() {
        store.flushNotes();
        diaryUnlocked = false;
        diaryQuery = "";
        cancelDiaryAuthentication();
        unlockSheet.close();
        if (isDiaryRecord(deleteSheet.kind, deleteSheet.recordId)) deleteSheet.close();
        undoTrashId = "";
        feedback = "";
    }
    function isDiaryRecord(kind, id) {
        return kind === "note" || (kind === "purge" && store.trash.some(entry => entry.id === id && entry.kind === "note"));
    }
    function browseDiary() {
        store.flushNotes();
        return guardNavigation(() => {
            page = "Diary"; selectedId = ""; diaryQuery = ""; feedback = "";
            diarySearchRequested = true;
            authorizeDiary(focusDiary);
        });
    }
    function openDiary(day) {
        store.flushNotes();
        return guardNavigation(() => {
            page = "Diary"; selectedId = ""; feedback = ""; setDiaryDate(day);
            diarySearchRequested = false;
            authorizeDiary(focusDiary);
        });
    }
    function searchJournal() {
        if (page === "Diary") {
            return guardNavigation(() => { diarySearchRequested = true; authorizeDiary(focusDiary); });
        }
        store.flushNotes();
        return guardNavigation(() => {
            page = "History"; selectedId = ""; feedback = "";
            mainScroll.contentItem.contentY = 0;
            Qt.callLater(() => { searchField.forceActiveFocus(Qt.ShortcutFocusReason); searchField.selectAll(); });
        });
    }
    function selectActivity(id) { guardNavigation(() => { selectedId = id; feedback = ""; }); }
    function requestClose() {
        unlockSheet.close();
        cancelDiaryAuthentication();
        if (calendarOpen) return false;
        store.flushNotes();
        for (const dialog of [safetySheet, sessionSheet, deleteSheet, shortcutsSheet])
            if (dialog.opened && !dialog.requestDismiss()) return false;
        if (store.hasUnsavedNotes || store.busy || detail.saving || composerSheet.saving) {
            closeFeedback = store.hasUnsavedNotes ? "Your note isn't saved yet. Retry or discard the draft before closing." : "Finishing your save…";
            return false;
        }
        if (detail.dirty || composerSheet.dirty) { guardNavigation(() => root.closeRequested()); return false; }
        return true;
    }
    function rememberFocus() { returnFocus = root.Window.window ? root.Window.window.activeFocusItem : null; }
    function restoreFocus() {
        if (returnFocus && returnFocus.visible) returnFocus.forceActiveFocus();
        else if (page === "Diary") {
            if (diaryUnlocked) focusDiary();
            else lockedDiary.focusUnlock();
        } else if (detail.visible) detail.forceActiveFocus();
        else addButton.forceActiveFocus();
    }
    function openComposer(mode, id) {
        if (store.loaded) guardNavigation(() => { rememberFocus(); composerSheet.begin(mode, id || ""); });
    }
    function openData() { guardNavigation(() => { rememberFocus(); safetySheet.begin(); }); }
    function openShortcuts() { rememberFocus(); shortcutsSheet.open(); }
    function focusAdd() { addButton.forceActiveFocus(Qt.TabFocusReason); }
    function sessionRows(entries) {
        // Capture each entry and its activity from the same snapshot.
        return entries.map(session => ({session: session, activity: store.activity(session.activityId)}));
    }
    function completeActivity(id) {
        if (actionPending) return;
        guardNavigation(() => {
            const activity = store.activity(id);
            if (!activity) return;
            actionPending = true;
            store.setDone(id, activity.status !== "done", (ok, result, error) => {
                actionPending = false;
                feedback = ok ? (activity.status === "done" ? "Activity reopened." : "Marked done.") : error.message;
            });
        });
    }
    function togglePinned(id) {
        if (actionPending) return;
        guardNavigation(() => {
            const activity = store.activity(id);
            if (!activity) return;
            actionPending = true;
            store.updateActivity(id, {pinned: !activity.pinned, expectedRevision: activity.revision}, (ok, result, error) => {
                actionPending = false;
                feedback = ok ? (activity.pinned ? "Activity unpinned." : "Pinned for quick access on every date.") : error.message;
            });
        });
    }
    function agendaEntries(section) {
        return store.activities.filter(activity => {
            if (activity.status === "done") return false;
            if (section === "Inbox") return !activity.plannedFor;
            if (section === "Today") return activity.plannedFor === store.today;
            if (section === "Tomorrow") return activity.plannedFor === offsetDay(store.today, 1);
            return activity.plannedFor && activity.plannedFor !== store.today && activity.plannedFor !== offsetDay(store.today, 1);
        });
    }
    function requestDelete(kind, id, revision, title) {
        store.flushNotes();
        if (kind === "note" && store.dirtyNotes[id]) { feedback = "Save or discard this note's draft before deleting it."; return; }
        guardNavigation(() => {
            const openConfirmation = () => { rememberFocus(); deleteSheet.begin(kind, id, revision, title); };
            if (isDiaryRecord(kind, id)) authorizeDiary(openConfirmation);
            else openConfirmation();
        });
    }
    function restoreDeleted(id) {
        if (undoSaving) return;
        if (store.trash.some(entry => entry.id === id && entry.kind === "note") && !diaryUnlocked) {
            authorizeDiary(() => restoreDeleted(id), "Unlock diary recovery");
            return;
        }
        undoSaving = true;
        store.undoDelete(id, (ok, result, error) => {
            undoSaving = false; feedback = ok ? "Restored." : error.message;
            if (ok && undoTrashId === id) undoTrashId = "";
        });
    }
    function updateHistoryFilters() {
        store.setHistoryFilters(page === "Diary" && diaryUnlocked ? diaryQuery : query,
            page === "Diary" && diaryUnlocked ? "notes" : "activities");
    }
    onQueryChanged: updateHistoryFilters()
    onDiaryQueryChanged: updateHistoryFilters()
    onDiaryUnlockedChanged: updateHistoryFilters()
    onPageChanged: {
        if (page !== "Diary") lockDiary();
        updateHistoryFilters();
    }
    Component.onCompleted: updateHistoryFilters()
    Connections {
        target: root.Window.window
        function onVisibleChanged() { if (!root.Window.window.visible) root.lockDiary(); }
        function onActiveChanged() { if (!root.Window.window.active) root.lockDiary(); }
    }
    Connections {
        target: root.diaryAuth
        function onAuthenticated() {
            const window = root.Window.window;
            if (!unlockSheet.opened || !root.diaryAction || !window || !window.visible || !window.active) {
                root.lockDiary();
                return;
            }
            const action = root.diaryAction;
            root.diaryAction = null;
            unlockSheet.close();
            root.diaryUnlocked = true;
            action();
        }
    }
    Connections {
        target: root.store
        function onDateChanged() { root.todayPage = 0; root.store.flushNotes(); dayPicker.text = root.store.date; }
        function onHasUnsavedNotesChanged() { if (!root.store.hasUnsavedNotes) root.closeFeedback = ""; }
    }
    Shortcut { sequence: "Ctrl+1"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Today") }
    Shortcut { sequence: "Ctrl+2"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Plan") }
    Shortcut { sequence: "Ctrl+3"; enabled: root.shortcutsAvailable; onActivated: root.navigate("History") }
    Shortcut { sequence: "Ctrl+4"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Diary") }
    Shortcut { sequence: "Ctrl+Shift+L"; enabled: root.diaryUnlocked; onActivated: root.lockDiary() }
    Shortcut { sequence: "Ctrl+N"; enabled: root.shortcutsAvailable; onActivated: root.openComposer("plan", "") }
    Shortcut { sequence: "Ctrl+L"; enabled: root.shortcutsAvailable; onActivated: root.openComposer("log", root.selectedId) }
    Shortcut { sequence: "Ctrl+J"; enabled: root.shortcutsAvailable; onActivated: root.openDiary(root.store.today) }
    Shortcut { sequence: "Ctrl+Shift+J"; enabled: root.shortcutsAvailable; onActivated: root.browseDiary() }
    Shortcut { sequence: "Ctrl+F"; enabled: root.shortcutsAvailable; onActivated: root.searchJournal() }
    Shortcut { sequence: "Ctrl+,"; enabled: root.shortcutsAvailable; onActivated: root.openData() }
    Shortcut { sequence: "Ctrl+/"; enabled: root.shortcutsAvailable; onActivated: root.openShortcuts() }
    Shortcut { sequence: "Ctrl+S"; enabled: root.shortcutsAvailable && root.page === "Diary" && root.diaryUnlocked; onActivated: root.store.flushNotes() }
    Shortcut {
        sequence: "Escape"; enabled: root.shortcutsAvailable
        onActivated: {
            if (root.selectedId) root.guardNavigation(() => { root.selectedId = ""; addButton.forceActiveFocus(); });
            else root.closeRequested();
        }
    }

    ColumnLayout {
        id: journalColumn
        objectName: "journalColumn"
        anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: root.theme.space(root.narrow ? 18 : 28)
        anchors.bottomMargin: root.theme.space(12)
        width: Math.min(root.width - root.theme.space(root.wideInsights ? 600 : root.narrow ? 32 : 64), root.theme.space(root.page === "Diary" ? 1240 : 820))
        spacing: root.theme.space(18)
        GridLayout {
            Layout.fillWidth: true
            columns: root.narrow ? 2 : 3
            columnSpacing: root.theme.space(16); rowSpacing: root.theme.space(12)
            RowLayout {
                Layout.row: 0; Layout.column: 0
                Rectangle { implicitWidth: root.theme.space(3); implicitHeight: root.theme.space(20); color: root.theme.accent }
                DText { theme: root.theme; text: "daymark"; font.pixelSize: root.theme.heading; font.bold: true; Layout.leftMargin: root.theme.space(5) }
            }
            RowLayout {
                Layout.row: root.narrow ? 1 : 0; Layout.column: root.narrow ? 0 : 1
                Layout.columnSpan: root.narrow ? 2 : 1
                Layout.fillWidth: true; spacing: root.theme.space(4)
                Repeater {
                    model: ["Today", "Plan", "History", "Diary"]
                    DButton {
                        required property string modelData
                        required property int index
                        shortcutHint: "Ctrl+" + (index + 1)
                        theme: root.theme; text: modelData; selected: root.page === modelData; quiet: true
                        objectName: "nav" + modelData
                        Layout.preferredWidth: root.theme.space(96)
                        onClicked: root.navigate(modelData)
                    }
                }
                Item { Layout.fillWidth: true }
            }
            DButton {
                Layout.row: 0; Layout.column: root.narrow ? 1 : 2; Layout.alignment: Qt.AlignRight
                theme: root.theme; text: "Data & Safety"; quiet: true; font.pixelSize: root.theme.small
                shortcutHint: "Ctrl+,"
                objectName: "dataSafetyOpen"; enabled: root.store.loaded; onClicked: root.openData()
            }
        }
        RowLayout {
            visible: root.feedback !== ""; Layout.fillWidth: true
            DText { theme: root.theme; objectName: "workspaceFeedback"; text: root.feedback; font.pixelSize: root.theme.small; Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Undo"; quiet: true; objectName: "undoDelete"; visible: root.undoTrashId !== ""; enabled: !root.undoSaving; onClicked: root.restoreDeleted(root.undoTrashId) }
            DButton { theme: root.theme; text: "Dismiss"; quiet: true; font.pixelSize: root.theme.small; onClicked: { root.feedback = ""; root.undoTrashId = ""; } }
        }
        RowLayout {
            visible: root.store.lastError !== "" || root.store.legacyError !== ""; Layout.fillWidth: true
            DText { theme: root.theme; text: root.store.legacyError || root.store.lastError; color: root.theme.urgent; Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Retry"; enabled: !root.store.busy; onClicked: root.store.legacyError ? root.store.settleLegacyTimers() : root.store.reload() }
        }
        ScrollView {
            id: mainScroll
            visible: root.selectedId === "" && root.page !== "Diary"
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: mainScroll.availableWidth
                spacing: root.theme.space(28)
                ColumnLayout {
                    Layout.fillWidth: true; spacing: root.theme.space(8)
                    RowLayout {
                        Layout.fillWidth: true
                        DText { theme: root.theme; text: root.page === "Today" ? (root.store.date === root.store.today ? "Today" : Display.day(root.store.date, root.store.today)) : root.page === "Plan" ? "Your plans" : "Your history"; font.pixelSize: root.theme.pageTitle; font.bold: true; Layout.fillWidth: true }
                        DButton {
                            id: addButton; theme: root.theme; primary: true; objectName: "addButton"; enabled: root.store.loaded
                            text: root.page === "History" ? "Log activity" : "Add activity"
                            shortcutHint: root.page === "History" ? "Ctrl+L" : "Ctrl+N"
                            onClicked: root.openComposer(root.page === "History" ? "log" : "plan", "")
                        }
                    }
                    RowLayout {
                        visible: root.page === "Today"; Layout.fillWidth: true
                        DateField { id: dayPicker; theme: root.theme; today: root.store.today; text: root.store.date; caption: root.dayLabel(root.store.date); fieldName: "workspaceDate"; onTextEdited: { if (root.store.validDate(text, false)) root.store.date = text; } }
                        Item { Layout.fillWidth: true }
                        DButton { theme: root.theme; quiet: true; text: "‹"; Accessible.name: "Previous day"; objectName: "previousDay"; onClicked: root.store.date = root.offsetDay(root.store.date, -1) }
                        DButton { theme: root.theme; quiet: true; text: "›"; Accessible.name: "Next day"; objectName: "nextDay"; onClicked: root.store.date = root.offsetDay(root.store.date, 1) }
                    }
                    DText { theme: root.theme; visible: root.page === "Plan"; text: "A few intentions, at your own pace."; color: root.theme.secondary; Layout.fillWidth: true }
                    DField { id: searchField; theme: root.theme; objectName: "historySearch"; visible: root.page === "History"; placeholderText: "Search activities and entries…"; Layout.fillWidth: true; text: root.query; onTextEdited: root.query = text }
                }
                DText { theme: root.theme; text: "Opening your journal…"; color: root.theme.secondary; visible: !root.store.loaded && root.store.busy; Layout.fillWidth: true }
                TodayView { id: todayView; workspace: root; visible: root.store.loaded && root.page === "Today"; Layout.fillWidth: true }
                PlanView { workspace: root; visible: root.store.loaded && root.page === "Plan"; Layout.fillWidth: true }
                HistoryView { workspace: root; visible: root.store.loaded && root.page === "History"; Layout.fillWidth: true }
                Item { implicitHeight: root.theme.space(12) }
            }
        }
        DiaryLocked {
            id: lockedDiary
            theme: root.theme
            visible: root.page === "Diary" && !root.diaryUnlocked
            Layout.fillWidth: true; Layout.fillHeight: true
            onUnlockRequested: root.authorizeDiary(root.focusDiary)
        }
        Loader {
            id: diaryLoader
            objectName: "diaryLoader"
            active: root.page === "Diary" && root.diaryUnlocked && root.store.loaded
            visible: active
            Layout.fillWidth: true; Layout.fillHeight: true
            sourceComponent: DiaryView { workspace: root }
        }
        ActivityDetail {
            id: detail
            theme: root.theme; store: root.store; activityId: root.selectedId
            showInsights: !root.wideInsights
            shortcutsEnabled: root.shortcutsAvailable
            actionsEnabled: !root.actionPending
            visible: root.selectedId !== ""; Layout.fillWidth: true; Layout.fillHeight: true
            onBackRequested: root.guardNavigation(() => { root.selectedId = ""; addButton.forceActiveFocus(); })
            onAddSessionRequested: id => root.openComposer("log", id)
            onCompleteRequested: id => root.completeActivity(id)
            onPinRequested: id => root.togglePinned(id)
            onEditSessionRequested: session => root.guardNavigation(() => { root.rememberFocus(); sessionSheet.begin(session); })
            onDeleteRequested: (kind, id, revision, title) => root.requestDelete(kind, id, revision, title)
        }
        ColumnLayout {
            Layout.fillWidth: true; spacing: root.theme.space(8)
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border; opacity: 0.35 }
            RowLayout {
                Layout.fillWidth: true; spacing: root.theme.space(12)
                Flow {
                    objectName: "footerShortcutHints"
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    spacing: root.theme.space(14)
                    opacity: root.shortcutsAvailable ? 1 : 0.45
                    Repeater {
                        model: [{keys: "Ctrl+N", purpose: "Plan"}, {keys: "Ctrl+L", purpose: "Log"}, {keys: "Ctrl+J", purpose: "Diary"}]
                        Row {
                            id: hint
                            required property var modelData
                            spacing: root.theme.space(7)
                            Keycap { theme: root.theme; text: hint.modelData.keys }
                            DText { theme: root.theme; text: hint.modelData.purpose; font.pixelSize: root.theme.small; color: root.theme.secondary; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
                DButton {
                    theme: root.theme; quiet: true; font.pixelSize: root.theme.small; text: "Ctrl+/  Shortcuts"
                    objectName: "shortcutsOpen"; enabled: root.shortcutsAvailable
                    Accessible.name: "Keyboard shortcuts, Control slash"
                    onClicked: root.openShortcuts()
                }
            }
            DText {
                theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                text: root.closeFeedback || (root.demoMode ? "SYNTHETIC DEMO · removed on exit" : root.temporaryProfile ? "TEMPORARY JOURNAL · removed on exit" : root.profileLabel)
                color: root.closeFeedback ? root.theme.urgent : root.theme.secondary
            }
        }
    }
    Loader {
        objectName: "journalInsightsLoader"
        active: root.wideInsights && root.store.loaded
        visible: active
        anchors.right: journalColumn.left; anchors.rightMargin: root.theme.space(48)
        anchors.top: journalColumn.top; anchors.topMargin: root.theme.space(58)
        anchors.bottom: journalColumn.bottom
        width: root.theme.space(220)
        sourceComponent: JournalInsights { theme: root.theme; summary: root.store.insights }
    }
    Loader {
        objectName: "activitySidebarLoader"
        active: root.wideInsights && root.store.loaded
        visible: active
        anchors.left: journalColumn.right; anchors.leftMargin: root.theme.space(48)
        anchors.top: journalColumn.top; anchors.topMargin: root.theme.space(58)
        anchors.bottom: journalColumn.bottom
        width: root.theme.space(220)
        sourceComponent: ScrollView {
            id: sideScroll
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: sideScroll.availableWidth
                Loader {
                    Layout.fillWidth: true
                    active: root.selectedId === ""
                    visible: active
                    sourceComponent: RecentActivities {
                        theme: root.theme; summary: root.store.insights; activitiesById: root.store.activitiesById
                        onActivityRequested: id => root.selectActivity(id)
                    }
                }
                Loader {
                    Layout.fillWidth: true
                    active: root.selectedId !== "" && !!root.store.activity(root.selectedId)
                    visible: active
                    sourceComponent: ActivityInsights {
                        theme: root.theme; activity: root.store.activity(root.selectedId)
                        stats: root.store.insights.byActivity[root.selectedId]; days: root.store.insights.days
                    }
                }
            }
        }
    }
    Composer { id: composerSheet; theme: root.theme; store: root.store; parent: root; onAccepted: id => { root.feedback = composerSheet.statusMessage; root.closeFeedback = ""; }; onClosed: root.restoreFocus() }
    DataSafety { id: safetySheet; parent: root; theme: root.theme; store: root.store; workspace: root; onClosed: { root.closeFeedback = ""; root.restoreFocus(); } }
    SessionEditor { id: sessionSheet; parent: root; theme: root.theme; store: root.store; onSaved: message => root.feedback = message; onClosed: { root.closeFeedback = ""; root.restoreFocus(); } }
    KeyboardShortcuts { id: shortcutsSheet; parent: root; theme: root.theme; onClosed: root.restoreFocus() }
    DiaryUnlock { id: unlockSheet; parent: root; theme: root.theme; authenticator: root.diaryAuth; onCancelled: root.cancelDiaryAuthentication() }
    DeleteConfirmation {
        id: deleteSheet; parent: root; theme: root.theme; store: root.store
        onClosed: root.restoreFocus()
        onDeleted: (kind, id) => {
            if (kind === "activity" && root.selectedId === id) root.selectedId = "";
            const entry = root.store.trash.find(value => value.kind === kind && value.recordId === id);
            root.undoTrashId = entry ? entry.id : "";
            root.feedback = kind === "purge" ? "Permanently deleted." : "Moved to Recently deleted.";
        }
    }
    Popup {
        id: confirmSheet; parent: root; anchors.centerIn: parent
        width: Math.min(root.width - root.theme.space(32), root.theme.space(460))
        modal: true; focus: true; padding: root.theme.space(24)
        onClosed: root.pendingNavigation = null
        background: Rectangle { color: root.theme.background; border.color: root.theme.border; radius: root.theme.radius }
        contentItem: ColumnLayout {
            spacing: root.theme.space(18)
            DText { theme: root.theme; text: "Keep your changes?"; font.pixelSize: root.theme.title; Layout.fillWidth: true }
            DText { theme: root.theme; text: "You have an unsaved draft."; color: root.theme.secondary; Layout.fillWidth: true }
            Flow {
                Layout.fillWidth: true; spacing: root.theme.gap
                DButton { theme: root.theme; text: "Keep editing"; primary: true; onClicked: confirmSheet.close() }
                DButton { theme: root.theme; text: "Discard changes"; quiet: true; objectName: "confirmTransition"; onClicked: { const action = root.pendingNavigation; detail.discardChanges(); composerSheet.discardChanges(); confirmSheet.close(); if (action) action(); } }
            }
        }
    }
}
