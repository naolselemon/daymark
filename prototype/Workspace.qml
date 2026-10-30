pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

Rectangle {
    id: root
    required property var theme
    required property var store
    required property var diaryAuth
    required property var updateTransport
    required property var calendarTransport
    required property var idleMonitor
    property var notificationTransport: null
    signal presentRequested()
    property alias preferences: preferencesController
    property alias updates: updateController
    property alias calendars: calendarController
    readonly property bool runtimeReady: store.loaded && preferencesController.loaded
        && countdown.loaded && updateController.loaded && calendarController.loaded
    property bool openingPending: true
    property bool openingApplied: false
    property bool safetyReturnsToSettings: false
    property bool calendarReturnsToSettings: false
    property string profileLabel: "Isolated profile"
    property bool demoMode: false
    property bool temporaryProfile: false
    property alias composer: composerSheet
    property alias countdownController: countdown
    property string page: "Timer"
    property string selectedId: ""
    property string query: ""
    // Keep an open page on its chosen date even while relative labels advance.
    property string diaryDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
    property string diaryQuery: ""
    property bool diaryUnlocked: false
    property bool diarySearchRequested: false
    property var diaryAction: null
    property bool diaryActionUnlocks: true
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
    readonly property bool pairedOverview: selectedId === "" && (page === "Today" || page === "Plan")
    readonly property bool planPinsInHeader: pairedOverview && page === "Plan" && pinnedActivities.length === 1 && activityContent.width >= theme.space(820)
    readonly property bool calendarOpen: dayPicker.calendarOpen || (detail.visible && detail.calendarOpen)
        || (diaryLoader.item && diaryLoader.item.calendarOpen)
    readonly property bool modalOpen: cleanupSheet.opened || calendarSheet.opened || targetSheet.opened || settingsSheet.opened || safetySheet.opened || sessionSheet.opened || deleteSheet.opened || shortcutsSheet.opened || unlockSheet.opened
    readonly property bool shortcutsAvailable: store.loaded && !updateController.applying && !modalOpen && !calendarOpen && !composerSheet.opened && !confirmSheet.opened
    readonly property var pinnedActivities: store.activities.filter(activity => activity.pinned)
    readonly property var movedPlans: store.events.filter(e => e.action === "reschedule" && e.from === store.date && store.activity(e.activityId))
    readonly property int todayPageCount: Math.max(1, Math.ceil(Math.max(store.planned(store.date).length,
        store.overdue(store.date).length, store.timeline(store.date).length, store.completionOnly(store.date).length, movedPlans.length) / 50))
    onTodayPageCountChanged: todayPage = Math.min(todayPage, todayPageCount - 1)
    readonly property string updateBlockReason: {
        if (!store.loaded || !preferencesController.loaded || !countdown.loaded || !calendarController.loaded)
            return "Wait for your journal and settings to finish loading.";
        if (store.hasUnsavedNotes || detail.dirty || composerSheet.dirty || calendarSheet.dirty)
            return "Save or discard your drafts before updating.";
        if (countdown.status === "running" || countdown.status === "paused")
            return "Finish or cancel the countdown before updating.";
        if (countdown.logPending)
            return qsTr("Retry the pending countdown entry before updating.");
        if (store.busy || preferencesController.busy || countdown.busy || calendarController.busy || detail.saving || composerSheet.saving || actionPending || undoSaving)
            return "Wait for the current operation to finish.";
        if (Object.keys(preferencesController.pendingChanges).length || preferencesController.pendingPage
                || preferencesController.retryRequest)
            return "Save or retry your settings before updating.";
        if (cleanupSheet.opened || cleanupSheet.saving || safetySheet.opened || safetySheet.saving || safetySheet.choosingFile || diaryAuthenticating
                || calendarSheet.opened || calendarOpen || composerSheet.opened || sessionSheet.opened || deleteSheet.opened || confirmSheet.opened)
            return "Close the current operation before updating.";
        if (!root.Window.window || !root.Window.window.visible || !root.Window.window.active)
            return "Open Settings to approve the shell restart.";
        return "";
    }
    readonly property string cleanupBlockReason: {
        if (!runtimeReady) return qsTr("Wait for your journal and settings to finish loading.");
        if (store.hasUnsavedNotes || detail.dirty || composerSheet.dirty || calendarSheet.dirty || sessionSheet.dirty || safetySheet.dirty)
            return qsTr("Save or discard your drafts before deleting activity data.");
        if (countdown.status === "running" || countdown.status === "paused"
                || (countdown.status === "finished" && countdown.activityId) || countdown.logPending)
            return qsTr("Finish logging or dismiss the linked countdown, or cancel the active countdown first.");
        if (store.legacySessions.length || countdown.retryRequest || countdown.error)
            return qsTr("Resolve the pending timer operation before deleting activity data.");
        if (updateController.busy || updateController.applying || updateController.refreshingAfterFailure
                || store.busy || preferencesController.busy || countdown.busy || calendarController.busy
                || detail.saving || composerSheet.saving || sessionSheet.saving || deleteSheet.saving || actionPending || undoSaving)
            return qsTr("Wait for the current operation to finish.");
        if (Object.keys(preferencesController.pendingChanges).length || preferencesController.pendingPage
                || preferencesController.retryRequest)
            return qsTr("Save or retry your settings before deleting activity data.");
        if (safetySheet.opened || safetySheet.saving || safetySheet.choosingFile || calendarSheet.opened
                || calendarOpen || composerSheet.opened || sessionSheet.opened || deleteSheet.opened || confirmSheet.opened)
            return qsTr("Close the current operation before deleting activity data.");
        if (!root.Window.window || !root.Window.window.visible || !root.Window.window.active)
            return qsTr("Keep Daymark open to approve deletion.");
        return "";
    }
    signal closeRequested()
    color: theme.background
    objectName: "workspace"

    function dayLabel(day) { return Qt.formatDate(new Date(day + "T12:00:00"), "dddd, d MMMM"); }
    function offsetDay(day, delta) {
        const value = new Date(day + "T12:00:00"); value.setDate(value.getDate() + delta);
        return Qt.formatDate(value, "yyyy-MM-dd");
    }
    function guardNavigation(action) {
        if (updateController.applying || modalOpen || calendarOpen) return false;
        if (detail.saving || composerSheet.saving) { feedback = "Finishing your save…"; return false; }
        if (detail.dirty || composerSheet.dirty) {
            pendingNavigation = action; confirmSheet.open(); return false;
        }
        action(); return true;
    }
    function navigate(target) {
        if (!preferencesController.loaded) openingPending = false;
        store.flushNotes();
        return guardNavigation(() => { page = target; selectedId = ""; feedback = ""; mainScroll.contentItem.contentY = 0; });
    }
    function applyOpeningPage() {
        if (!root.Window.window || !root.Window.window.visible) return;
        if (!preferencesController.loaded) { openingPending = true; return; }
        openingPending = false;
        // A reopened workspace may still own a failed draft or file chooser.
        if (store.hasUnsavedNotes || detail.dirty || composerSheet.dirty || modalOpen || calendarOpen) return;
        const target = preferencesController.openingPage === "last"
            ? (openingApplied ? page : preferencesController.lastPage) : preferencesController.openingPage;
        if (navigate(target)) openingApplied = true;
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
    function authorizeDiary(action, purpose = "Unlock your diary", fresh = false) {
        if (unlockSheet.opened) return false;
        if (diaryUnlocked && !fresh) { action(); return true; }
        if (fresh) lockDiary();
        diaryActionUnlocks = !fresh;
        diaryAction = action;
        unlockSheet.authorizationOnly = fresh;
        unlockSheet.begin(purpose);
        return false;
    }
    function cancelDiaryAuthentication() {
        if (diaryAction) cleanupSheet.authenticationCancelled();
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
        if (cleanupSheet.saving) { closeFeedback = qsTr("Finishing deletion. Keep Daymark open until the result is known."); return false; }
        if (updateController.applying) { closeFeedback = "Finishing the update. Keep Daymark open until the result is known."; return false; }
        unlockSheet.close();
        cancelDiaryAuthentication();
        if (calendarOpen) return false;
        store.flushNotes();
        const returnToSettings = safetyReturnsToSettings;
        const returnFromCalendar = calendarReturnsToSettings;
        safetyReturnsToSettings = false;
        calendarReturnsToSettings = false;
        for (const dialog of [cleanupSheet, calendarSheet, targetSheet, safetySheet, settingsSheet, sessionSheet, deleteSheet, shortcutsSheet]) {
            if (!dialog.opened || dialog.requestDismiss()) continue;
            safetyReturnsToSettings = returnToSettings;
            calendarReturnsToSettings = returnFromCalendar;
            return false;
        }
        if (store.hasUnsavedNotes || store.busy || preferencesController.busy || calendarController.busy || detail.saving || composerSheet.saving) {
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
        else if (page === "Timer") timerView.forceActiveFocus();
        else addButton.forceActiveFocus();
    }
    function openComposer(mode, id) {
        if (store.loaded) guardNavigation(() => { rememberFocus(); composerSheet.begin(mode, id || ""); });
    }
    function chooseCountdownTarget() {
        if (countdown.status !== "idle" || countdown.busy || countdown.logPending) return;
        guardNavigation(() => {
            rememberFocus();
            targetSheet.begin(countdown.selectedActivityId, countdown.selectedTaskId);
        });
    }
    function timerForTask(activityId, taskId) {
        guardNavigation(() => {
            page = "Timer";
            selectedId = "";
            if (!countdown.selectTarget(activityId, taskId))
                feedback = countdown.logPending ? qsTr("Retry the pending entry before changing the countdown.")
                    : qsTr("Cancel or dismiss the current countdown before choosing another target.");
            else feedback = "";
            timerView.forceActiveFocus();
        });
    }
    function logTask(activityId, taskId) {
        if (store.loaded) guardNavigation(() => {
            rememberFocus();
            composerSheet.beginLogTask(activityId, taskId, store.date);
        });
    }
    function logCountdown() {
        if (!store.loaded || countdown.busy || countdown.status !== "finished" || !countdown.activityId) return;
        guardNavigation(() => {
            rememberFocus();
            composerSheet.beginCountdown(countdown.activityId, countdown.taskId, countdown.runId, store.date);
        });
    }
    function openSettings() {
        guardNavigation(() => {
            rememberFocus();
            lockDiary();
            settingsSheet.begin();
        });
    }
    function openDataSafety() {
        safetyReturnsToSettings = true;
        if (!settingsSheet.requestDismiss()) { safetyReturnsToSettings = false; return; }
        safetySheet.begin();
    }
    function openCalendars() {
        calendarReturnsToSettings = true;
        if (!settingsSheet.requestDismiss()) { calendarReturnsToSettings = false; return; }
        calendarSheet.begin();
    }
    function openActivityCleanup(operation) {
        if (cleanupBlockReason || !settingsSheet.opened) return;
        cleanupSheet.begin(operation);
    }
    function openShortcuts() { rememberFocus(); shortcutsSheet.open(); }
    function focusAdd() { addButton.forceActiveFocus(Qt.TabFocusReason); }
    function sessionRows(entries) {
        // Capture each entry and its activity from the same snapshot.
        return entries.map(session => ({session: session, activity: store.activity(session.activityId)}));
    }
    function completeActivity(id) {
        if (actionPending || countdown.logPending) return;
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
    function completeTask(activityId, taskId) {
        if (actionPending || countdown.logPending) return;
        guardNavigation(() => {
            const activity = store.activity(activityId);
            const task = activity ? (activity.tasks || []).find(value => value.id === taskId) : null;
            if (!task) return;
            actionPending = true;
            store.setTaskDone(activityId, taskId, !task.done, (ok, result, error) => {
                actionPending = false;
                feedback = ok ? (task.done ? qsTr("Task reopened.") : qsTr("Task completed.")) : error.message;
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
        cleanupSheet.revokeAuthorization();
        if (!cleanupSheet.saving) cleanupSheet.close();
        if (page !== "Diary") lockDiary();
        updateHistoryFilters();
        if (!preferencesController.loaded) openingPending = false;
        if (preferencesController.loaded && !openingPending) preferencesController.rememberPage(page);
    }
    Component.onCompleted: {
        updateHistoryFilters();
        Qt.callLater(applyOpeningPage);
    }
    Connections {
        target: root.Window.window
        function onVisibleChanged() {
            if (!root.Window.window.visible) { cleanupSheet.revokeAuthorization(); root.lockDiary(); }
            else root.applyOpeningPage();
        }
        function onActiveChanged() {
            if (!root.Window.window.active) { cleanupSheet.revokeAuthorization(); root.lockDiary(); }
        }
    }
    Connections {
        target: preferencesController
        function onLoadedChanged() {
            if (!preferencesController.loaded) return;
            if (root.openingPending) root.applyOpeningPage();
            else {
                root.openingApplied = true;
                preferencesController.rememberPage(root.page);
            }
        }
    }
    Binding {
        target: root.idleMonitor
        property: "timeout"
        value: preferencesController.diaryIdleMinutes * 60
    }
    Binding {
        target: root.idleMonitor
        property: "enabled"
        value: root.diaryUnlocked && preferencesController.loaded && preferencesController.diaryIdleMinutes > 0
    }
    Connections {
        target: root.idleMonitor
        function onIsIdleChanged() {
            if (root.idleMonitor.isIdle && root.diaryUnlocked && preferencesController.diaryIdleMinutes > 0)
                root.lockDiary();
        }
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
            const unlocks = root.diaryActionUnlocks;
            root.diaryAction = null;
            unlockSheet.close();
            root.diaryUnlocked = unlocks;
            action();
        }
    }
    Connections {
        target: root.store
        function onDateChanged() { root.todayPage = 0; root.store.flushNotes(); dayPicker.text = root.store.date; }
        function onHasUnsavedNotesChanged() { if (!root.store.hasUnsavedNotes) root.closeFeedback = ""; }
    }
    Shortcut { sequence: "Ctrl+1"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Timer") }
    Shortcut { sequence: "Ctrl+2"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Today") }
    Shortcut { sequence: "Ctrl+3"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Plan") }
    Shortcut { sequence: "Ctrl+4"; enabled: root.shortcutsAvailable; onActivated: root.navigate("History") }
    Shortcut { sequence: "Ctrl+5"; enabled: root.shortcutsAvailable; onActivated: root.navigate("Diary") }
    Shortcut { sequence: "Ctrl+Shift+L"; enabled: root.diaryUnlocked; onActivated: root.lockDiary() }
    Shortcut { sequence: "Ctrl+N"; enabled: root.shortcutsAvailable; onActivated: root.openComposer("plan", "") }
    Shortcut { sequence: "Ctrl+L"; enabled: root.shortcutsAvailable; onActivated: root.openComposer("log", root.selectedId) }
    Shortcut { sequence: "Ctrl+J"; enabled: root.shortcutsAvailable; onActivated: root.openDiary(root.store.today) }
    Shortcut { sequence: "Ctrl+Shift+J"; enabled: root.shortcutsAvailable; onActivated: root.browseDiary() }
    Shortcut { sequence: "Ctrl+F"; enabled: root.shortcutsAvailable; onActivated: root.searchJournal() }
    Shortcut { sequence: "Ctrl+,"; enabled: root.shortcutsAvailable; onActivated: root.openSettings() }
    Shortcut { sequence: "Ctrl+/"; enabled: root.shortcutsAvailable; onActivated: root.openShortcuts() }
    Shortcut { sequence: "Ctrl+S"; enabled: root.shortcutsAvailable && root.page === "Diary" && root.diaryUnlocked; onActivated: root.store.flushNotes() }
    Shortcut {
        sequence: "Escape"; enabled: root.shortcutsAvailable
        onActivated: {
            if (root.selectedId) root.guardNavigation(() => { root.selectedId = ""; addButton.forceActiveFocus(); });
            else root.closeRequested();
        }
    }

    PreferencesController { id: preferencesController; store: root.store }
    UpdateController {
        id: updateController
        transport: root.updateTransport
        preferences: preferencesController
        canApply: root.updateBlockReason === ""
        blockReason: root.updateBlockReason
    }
    CountdownController {
        id: countdown; store: root.store; suspended: updateController.applying || cleanupSheet.saving
        onCompletionClaimed: (runId, revision, activityTitle, taskTitle) => timerNotifications.announce(runId, revision, activityTitle, taskTitle)
    }
    TimerNotificationController {
        id: timerNotifications
        transport: root.notificationTransport
        onActivated: {
            root.presentRequested();
            Qt.callLater(() => root.navigate("Timer"));
        }
        onCalendarActivated: {
            root.presentRequested();
            Qt.callLater(() => root.guardNavigation(() => {
                root.store.date = root.store.today;
                root.navigate("Today");
            }));
        }
    }
    CalendarController {
        id: calendarController
        transport: root.calendarTransport
        viewDate: root.store.date || Qt.formatDate(new Date(), "yyyy-MM-dd")
        suspended: updateController.applying
    }
    CalendarReminderController {
        calendar: calendarController
        enabled: !updateController.applying && !!root.notificationTransport && root.notificationTransport.enabled
            && !(root.calendarTransport && root.calendarTransport.readOnly === true)
        onReminderClaimed: (occurrenceId, startEpoch, title) => timerNotifications.announceCalendar(occurrenceId, startEpoch, title)
    }

    ColumnLayout {
        id: journalColumn
        objectName: "journalColumn"
        enabled: !updateController.applying
        anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: root.theme.space(root.narrow ? 18 : 28)
        anchors.bottomMargin: root.theme.space(12)
        width: Math.min(root.width - root.theme.space(root.narrow ? 32 : 64), root.theme.space(1240))
        spacing: root.theme.space(18)
        GridLayout {
            id: workspaceHeader
            objectName: "workspaceHeader"
            // Measure both presentations independently of the current button widths,
            // so changing presentation cannot feed back into its own fit decision.
            readonly property real compactNavigationWidth: navigationWidth(true)
            readonly property real labeledNavigationWidth: navigationWidth(false)
            readonly property real inlineNavigationWidth: width - headerBrand.implicitWidth
                - settingsButton.implicitWidth - 2 * columnSpacing
            readonly property bool compactNavigation: root.narrow || labeledNavigationWidth > inlineNavigationWidth
            readonly property bool navigationWrapped: compactNavigationWidth > inlineNavigationWidth
            readonly property bool brandActionsStacked: width < headerBrand.implicitWidth
                + settingsButton.implicitWidth + columnSpacing
            function navigationWidth(compact) {
                let total = Math.max(0, navigationRepeater.count - 1) * root.theme.space(compact ? 12 : 4);
                for (let index = 0; index < navigationRepeater.count; ++index) {
                    const button = navigationRepeater.itemAt(index);
                    if (button) total += compact ? button.compactWidth : button.labeledWidth;
                }
                return total;
            }
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.maximumWidth: Infinity
            columns: brandActionsStacked ? 1 : navigationWrapped ? 2 : 3
            columnSpacing: root.theme.space(16); rowSpacing: root.theme.space(12)
            DButton {
                id: headerBrand
                objectName: "headerBrand"
                theme: root.theme; quiet: true
                text: "Daymark quotes"
                Accessible.description: "Open the quote page"
                Layout.row: 0; Layout.column: 0
                Layout.alignment: Qt.AlignLeft
                padding: 0; leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                onClicked: root.navigate("Quotes")
                contentItem: RowLayout {
                    spacing: root.theme.space(10)
                    DaymarkMark {
                        objectName: "headerLogo"
                        Layout.preferredWidth: root.theme.space(38); Layout.preferredHeight: root.theme.space(38)
                        ink: root.theme.foreground; accent: root.theme.accent
                    }
                    DText {
                        objectName: "headerName"
                        theme: root.theme; text: "daymark"; font.pixelSize: root.theme.heading; font.bold: true
                    }
                }
            }
            Flow {
                id: headerNavigation
                objectName: "headerNavigation"
                Layout.row: workspaceHeader.brandActionsStacked ? 2 : workspaceHeader.navigationWrapped ? 1 : 0
                Layout.column: workspaceHeader.navigationWrapped ? 0 : 1
                Layout.columnSpan: workspaceHeader.navigationWrapped && !workspaceHeader.brandActionsStacked ? 2 : 1
                Layout.fillWidth: true; Layout.minimumWidth: 0
                Layout.preferredWidth: workspaceHeader.compactNavigation
                    ? workspaceHeader.compactNavigationWidth : workspaceHeader.labeledNavigationWidth
                readonly property real extraCompactGap: Math.max(0, Math.min(root.theme.space(20),
                    (width - workspaceHeader.compactNavigationWidth) / Math.max(1, navigationRepeater.count - 1)))
                spacing: workspaceHeader.compactNavigation ? root.theme.space(12) + extraCompactGap : root.theme.space(4)
                leftPadding: workspaceHeader.compactNavigation
                    ? Math.max(0, (width - workspaceHeader.compactNavigationWidth
                        - extraCompactGap * Math.max(0, navigationRepeater.count - 1)) / 2) : 0
                Repeater {
                    id: navigationRepeater
                    model: ["Timer", "Today", "Plan", "History", "Diary"]
                    DButton {
                        required property string modelData
                        required property int index
                        id: navigationButton
                        readonly property real compactWidth: Math.max(root.theme.space(44),
                            root.theme.space(22) + 2 * root.theme.space(10) + 2)
                        readonly property real labeledWidth: Math.max(root.theme.space(44),
                            navigationLabelMetrics.width + root.theme.space(30)
                            + 2 * Math.max(root.theme.source.spacing["control-padding-x"], root.theme.space(14)) + 2)
                        TextMetrics {
                            id: navigationLabelMetrics
                            text: navigationButton.text
                            font.family: navigationButton.font.family
                            font.pixelSize: navigationButton.font.pixelSize
                            // Reserve selected-label width so switching pages never moves navigation.
                            font.bold: true
                        }
                        shortcutHint: "Ctrl+" + (index + 1)
                        theme: root.theme; text: modelData; selected: root.page === modelData; quiet: true
                        iconName: ["timer", "today", "plan", "history", "diary"][index]
                        iconOnly: workspaceHeader.compactNavigation
                        objectName: "nav" + modelData
                        width: iconOnly ? compactWidth : labeledWidth
                        onClicked: root.navigate(modelData)
                    }
                }
            }
            DButton {
                id: settingsButton
                Layout.row: workspaceHeader.brandActionsStacked ? 1 : 0
                Layout.column: workspaceHeader.brandActionsStacked ? 0 : workspaceHeader.navigationWrapped ? 1 : 2
                Layout.alignment: Qt.AlignRight
                theme: root.theme; text: "Settings"; quiet: true; font.pixelSize: root.theme.small
                iconName: "settings"
                shortcutHint: "Ctrl+,"
                objectName: "settingsOpen"; enabled: root.store.loaded; onClicked: root.openSettings()
            }
        }
        RowLayout {
            visible: root.feedback !== ""; Layout.fillWidth: true
            DText { theme: root.theme; objectName: "workspaceFeedback"; text: root.feedback; font.pixelSize: root.theme.small; Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Undo"; iconName: "undo"; quiet: true; objectName: "undoDelete"; visible: root.undoTrashId !== ""; enabled: !root.undoSaving; onClicked: root.restoreDeleted(root.undoTrashId) }
            DButton { theme: root.theme; text: "Dismiss"; iconName: "close"; quiet: true; font.pixelSize: root.theme.small; onClicked: { root.feedback = ""; root.undoTrashId = ""; } }
        }
        RowLayout {
            visible: root.store.lastError !== "" || root.store.legacyError !== ""; Layout.fillWidth: true
            DText { theme: root.theme; text: root.store.legacyError || root.store.lastError; color: root.theme.urgent; Layout.fillWidth: true }
            DButton { theme: root.theme; text: "Retry"; iconName: "retry"; enabled: !root.store.busy; onClicked: root.store.legacyError ? root.store.settleLegacyTimers() : root.store.reload() }
        }
        TimerView {
            id: timerView
            theme: root.theme; controller: countdown; store: root.store
            notificationError: timerNotifications.error
            onTargetRequested: root.chooseCountdownTarget()
            onLogRequested: root.logCountdown()
            shortcutsEnabled: root.shortcutsAvailable && root.page === "Timer"
            visible: root.page === "Timer"
            Layout.fillWidth: true; Layout.fillHeight: true
        }
        QuoteView {
            theme: root.theme
            visible: root.page === "Quotes"
            active: visible && root.visible && !!root.Window.window && root.Window.window.visible
            onlineEnabled: preferencesController.loaded && preferencesController.onlineQuotes
            Layout.fillWidth: true; Layout.fillHeight: true
        }
        RowLayout {
            visible: root.page !== "Diary" && root.page !== "Timer" && root.page !== "Quotes"
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: root.theme.space(32)
            Rectangle {
                id: activityPaper
                objectName: "activityPaper"
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
                color: "transparent"
                ColumnLayout {
                    id: activityContent
                    anchors.fill: parent
                    spacing: root.theme.space(24)
                    GridLayout {
                        id: pageHeader
                        visible: root.selectedId === ""
                        Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.maximumWidth: Infinity
                        Layout.bottomMargin: root.theme.space(12)
                        columns: root.planPinsInHeader ? 3 : 2
                        columnSpacing: root.theme.space(16); rowSpacing: root.theme.space(12)
                        ColumnLayout {
                            Layout.row: 0; Layout.column: 0
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            spacing: root.theme.space(8)
                            PagePrompt {
                                objectName: "activityPagePrompt"
                                theme: root.theme
                                page: root.page
                                Layout.fillWidth: true; Layout.minimumWidth: 0
                            }
                        }
                        GridLayout {
                            visible: root.page === "Today"
                            Layout.row: 1; Layout.column: 0; Layout.columnSpan: 2
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            columns: width >= root.theme.space(560) ? 2 : 1
                            columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(4)
                            DText {
                                theme: root.theme; text: root.dayLabel(root.store.date)
                                color: root.theme.secondary; font.pixelSize: root.theme.small
                                Layout.maximumWidth: parent.width
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: root.theme.space(8)
                                DButton { theme: root.theme; quiet: true; text: "Previous day"; iconName: "previous"; objectName: "previousDay"; onClicked: root.store.date = root.offsetDay(root.store.date, -1) }
                                DateField {
                                    id: dayPicker
                                    theme: root.theme; today: root.store.today; text: root.store.date
                                    caption: root.dayLabel(root.store.date); fieldName: "workspaceDate"; iconOnly: true
                                    onTextEdited: { if (root.store.validDate(text, false)) root.store.date = text; }
                                }
                                DButton { theme: root.theme; quiet: true; text: "Next day"; iconName: "next"; objectName: "nextDay"; onClicked: root.store.date = root.offsetDay(root.store.date, 1) }
                                Item { Layout.fillWidth: true }
                            }
                        }
                        PinnedActivities {
                            workspace: root; visible: root.planPinsInHeader
                            Layout.row: 0; Layout.column: 1
                            Layout.preferredWidth: root.theme.space(340); Layout.maximumWidth: root.theme.space(340)
                        }
                        RowLayout {
                            Layout.row: 0; Layout.column: pageHeader.columns - 1
                            Layout.maximumWidth: implicitWidth; Layout.alignment: Qt.AlignRight
                            spacing: root.theme.space(8)
                            DButton {
                                theme: root.theme; quiet: true; text: "Open diary"; shortcutHint: "Ctrl+J"; objectName: "todayOpenDiary"
                                visible: root.page === "Today"; enabled: root.store.loaded
                                iconName: "diary"
                                onClicked: root.openDiary(root.store.today)
                            }
                            DButton {
                                id: addButton
                                theme: root.theme; primary: true; objectName: "addButton"; enabled: root.store.loaded
                                text: root.page === "History" ? "Log activity" : "Add plan"
                                iconName: root.page === "History" ? "log" : "add"
                                shortcutHint: root.page === "History" ? "Ctrl+L" : "Ctrl+N"
                                onClicked: root.openComposer(root.page === "History" ? "log" : "plan", "")
                            }
                        }
                        DField {
                            id: searchField
                            theme: root.theme; objectName: "historySearch"; visible: root.page === "History"
                            placeholderText: "Search activities and entries…"
                            Layout.row: 1; Layout.column: 0; Layout.columnSpan: pageHeader.columns
                            Layout.fillWidth: true; text: root.query; onTextEdited: root.query = text
                        }
                        Rectangle { visible: !root.pairedOverview; Layout.row: 2; Layout.column: 0; Layout.columnSpan: pageHeader.columns; Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border; opacity: 0.35 }
                    }
                    ScrollView {
                        id: mainScroll
                        objectName: "activityScroll"
                        visible: root.selectedId === ""
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentWidth: availableWidth; clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        ColumnLayout {
                            width: mainScroll.availableWidth
                            spacing: root.theme.space(24)
                            DText { theme: root.theme; text: "Opening your journal…"; color: root.theme.secondary; visible: !root.store.loaded && root.store.busy; Layout.fillWidth: true }
                            TodayView { id: todayView; workspace: root; calendarController: root.calendars; visible: root.store.loaded && root.page === "Today"; Layout.fillWidth: true }
                            PlanView { workspace: root; calendarController: root.calendars; visible: root.store.loaded && root.page === "Plan"; Layout.fillWidth: true }
                            Rectangle {
                                objectName: "historyCard"
                                visible: root.store.loaded && root.page === "History"
                                Layout.fillWidth: true; Layout.minimumWidth: 0
                                implicitHeight: historyContents.implicitHeight + root.theme.space(40)
                                color: root.theme.surface; radius: root.theme.radius
                                border.color: Qt.rgba(root.theme.border.r, root.theme.border.g, root.theme.border.b, root.theme.border.a * 0.4)
                                HistoryView {
                                    id: historyContents
                                    objectName: "historyView"; workspace: root
                                    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                                    anchors.margins: root.theme.space(20)
                                }
                            }
                            ColumnLayout {
                                id: overviewSection
                                property bool todayExpanded: false
                                property bool planExpanded: false
                                readonly property bool disclosed: root.page === "Today" ? todayExpanded : planExpanded
                                visible: root.store.loaded && root.selectedId === "" && (root.pairedOverview || root.page === "History")
                                Layout.fillWidth: true; Layout.minimumWidth: 0
                                spacing: root.theme.space(12)
                                Rectangle { visible: root.pairedOverview; Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                                DisclosureHeading {
                                    objectName: "pageInsightsToggle"
                                    theme: root.theme; title: qsTr("14-day insights")
                                    visible: root.pairedOverview; Layout.fillWidth: true
                                    summary: !root.store.insights ? "" : (root.store.insights.entryCount === 1
                                        ? qsTr("1 entry") : qsTr("%1 entries").arg(root.store.insights.entryCount))
                                        + " · " + (root.store.insights.activeDays === 1
                                        ? qsTr("1 active day") : qsTr("%1 active days").arg(root.store.insights.activeDays))
                                    expanded: overviewSection.disclosed
                                    onClicked: {
                                        if (root.page === "Today") overviewSection.todayExpanded = !overviewSection.todayExpanded;
                                        else overviewSection.planExpanded = !overviewSection.planExpanded;
                                    }
                                }
                                OverviewInsights {
                                    theme: root.theme; summary: root.store.insights; activitiesById: root.store.activitiesById
                                    visible: root.page === "History" || overviewSection.disclosed
                                    fullyExpanded: root.pairedOverview
                                    Layout.fillWidth: true
                                    onActivityRequested: id => root.selectActivity(id)
                                }
                            }
                            Item { implicitHeight: root.theme.space(8) }
                        }
                    }
                    ActivityDetail {
                        id: detail
                        theme: root.theme; store: root.store; activityId: root.selectedId
                        shortcutsEnabled: root.shortcutsAvailable
                        actionsEnabled: !root.actionPending && !countdown.logPending
                        visible: root.selectedId !== ""; Layout.fillWidth: true; Layout.fillHeight: true
                        onBackRequested: root.guardNavigation(() => { root.selectedId = ""; addButton.forceActiveFocus(); })
                        onAddSessionRequested: id => root.openComposer("log", id)
                        onTimerRequested: (activityId, taskId) => root.timerForTask(activityId, taskId)
                        onLogTaskRequested: (activityId, taskId) => root.logTask(activityId, taskId)
                        onCompleteRequested: id => root.completeActivity(id)
                        onTaskCompleteRequested: (activityId, taskId) => root.completeTask(activityId, taskId)
                        onPinRequested: id => root.togglePinned(id)
                        onEditSessionRequested: session => root.guardNavigation(() => { root.rememberFocus(); sessionSheet.begin(session); })
                        onDeleteRequested: (kind, id, revision, title) => root.requestDelete(kind, id, revision, title)
                    }
                }
            }
        }
        PagePrompt {
            objectName: "diaryPagePrompt"
            theme: root.theme
            page: "Diary"
            visible: root.page === "Diary"
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.bottomMargin: root.theme.space(12)
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
        ColumnLayout {
            visible: root.page !== "Quotes" || root.closeFeedback !== ""
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
                        model: root.page === "Diary" && root.diaryUnlocked
                            ? [{keys: "Ctrl+S", purpose: "Save"}, {keys: "Ctrl+F", purpose: "Find"}, {keys: "Ctrl+Shift+L", purpose: "Lock"}]
                            : root.page === "Timer" ? [{keys: "Enter", purpose: "Start / pause"}, {keys: "0–9", purpose: "Duration"}, {keys: "⌫", purpose: "Erase"}]
                            : [{keys: "Ctrl+N", purpose: "Plan"}, {keys: "Ctrl+L", purpose: "Log"}, {keys: "Ctrl+J", purpose: "Diary"}]
                        Row {
                            id: hint
                            required property var modelData
                            spacing: root.theme.space(7)
                            Keycap { theme: root.theme; text: hint.modelData.keys }
                            DText { theme: root.theme; text: hint.modelData.purpose; font.pixelSize: root.theme.small; font.italic: true; color: root.theme.secondary; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
                DButton {
                    theme: root.theme; quiet: true; text: "Keyboard shortcuts"; iconName: "keyboard"; shortcutHint: "Ctrl+/"
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
    Composer { id: composerSheet; theme: root.theme; store: root.store; countdown: root.countdownController; parent: root; onAccepted: id => { root.feedback = composerSheet.statusMessage; root.closeFeedback = ""; }; onClosed: root.restoreFocus() }
    CountdownTargetPicker {
        id: targetSheet; parent: root; theme: root.theme; store: root.store
        onChosen: (activityId, taskId) => {
            if (!countdown.selectTarget(activityId, taskId))
                root.feedback = qsTr("The countdown changed. Cancel or dismiss it before choosing another target.");
        }
        onClosed: root.restoreFocus()
    }
    SettingsDialog {
        id: settingsSheet; parent: root
        theme: root.theme; preferences: preferencesController; countdown: countdown; updater: updateController
        enabled: !updateController.applying
        cleanupBlockReason: root.cleanupBlockReason
        onCleanupRequested: operation => root.openActivityCleanup(operation)
        onDataRequested: root.openDataSafety()
        onCalendarsRequested: root.openCalendars()
        onRestartRequested: commit => updateController.applyApproved(commit)
        onClosed: {
            if (!cleanupSheet.saving) cleanupSheet.requestDismiss();
            if (!root.safetyReturnsToSettings && !root.calendarReturnsToSettings) root.restoreFocus();
        }
    }
    ActivityCleanupDialog {
        id: cleanupSheet; parent: root
        theme: root.theme; store: root.store; workspace: root
        onCompleted: (operation, result) => {
            root.undoTrashId = "";
            root.todayPage = 0;
            root.selectedId = "";
            if (!root.store.activity(countdown.selectedActivityId)) {
                countdown.selectedActivityId = "";
                countdown.selectedTaskId = "";
            }
            root.feedback = operation === "wipe_activity_data"
                ? qsTr("All activity data deleted. Diary, settings and Calendar kept.")
                : qsTr("Today's activity entries deleted. Plans and completion states kept.");
            Qt.callLater(countdown.refresh);
        }
        onClosed: if (settingsSheet.opened) settingsSheet.forceActiveFocus(Qt.PopupFocusReason)
    }
    CalendarDialog {
        id: calendarSheet; parent: root
        theme: root.theme; controller: calendarController
        notificationError: timerNotifications.calendarError
        onBackRequested: {
            const returnToSettings = root.calendarReturnsToSettings;
            root.calendarReturnsToSettings = false;
            if (returnToSettings && root.Window.window && root.Window.window.visible) settingsSheet.begin();
            else root.restoreFocus();
        }
    }
    DataSafety {
        id: safetySheet; parent: root; theme: root.theme; store: root.store; workspace: root
        onClosed: {
            root.closeFeedback = "";
            const returnToSettings = root.safetyReturnsToSettings;
            root.safetyReturnsToSettings = false;
            if (returnToSettings && root.Window.window && root.Window.window.visible) settingsSheet.begin();
            else root.restoreFocus();
        }
    }
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
