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
    function authorizeDiary(action, purpose = "Unlock your diary", fresh = false) {
        if (unlockSheet.opened) return false;
        if (diaryUnlocked && !fresh) { action(); return true; }
        if (fresh) lockDiary();
        diaryActionUnlocks = !fresh;
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
        else if (page === "Timer") timerView.forceActiveFocus();
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

    CountdownController { id: countdown; store: root.store }

    ColumnLayout {
        id: journalColumn
        objectName: "journalColumn"
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
                - dataSafetyButton.implicitWidth - 2 * columnSpacing
            readonly property bool compactNavigation: root.narrow || labeledNavigationWidth > inlineNavigationWidth
            readonly property bool navigationWrapped: compactNavigationWidth > inlineNavigationWidth
            readonly property bool brandActionsStacked: width < headerBrand.implicitWidth
                + dataSafetyButton.implicitWidth + columnSpacing
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
                id: dataSafetyButton
                Layout.row: workspaceHeader.brandActionsStacked ? 1 : 0
                Layout.column: workspaceHeader.brandActionsStacked ? 0 : workspaceHeader.navigationWrapped ? 1 : 2
                Layout.alignment: Qt.AlignRight
                theme: root.theme; text: "Data & Safety"; quiet: true; font.pixelSize: root.theme.small
                iconName: "shield"
                shortcutHint: "Ctrl+,"
                objectName: "dataSafetyOpen"; enabled: root.store.loaded; onClicked: root.openData()
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
            theme: root.theme; controller: countdown
            shortcutsEnabled: root.shortcutsAvailable && root.page === "Timer"
            visible: root.page === "Timer"
            Layout.fillWidth: true; Layout.fillHeight: true
        }
        QuoteView {
            theme: root.theme
            visible: root.page === "Quotes"
            active: visible && root.visible && !!root.Window.window && root.Window.window.visible
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
                        readonly property bool centeredDate: root.page === "Today" && width >= root.theme.space(700)
                        visible: root.selectedId === ""
                        Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.maximumWidth: Infinity
                        columns: centeredDate || root.planPinsInHeader ? 3 : 2
                        uniformCellWidths: centeredDate
                        columnSpacing: root.theme.space(16); rowSpacing: root.theme.space(12)
                        ColumnLayout {
                            Layout.row: 0; Layout.column: 0
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            spacing: root.theme.space(8)
                            DText {
                                theme: root.theme
                                text: root.page === "Today" ? (root.store.date === root.store.today ? "Today" : Display.day(root.store.date, root.store.today)) : root.page
                                font.pixelSize: root.narrow ? root.theme.title : root.theme.pageTitle
                                font.bold: true; font.italic: true
                                Layout.fillWidth: true; Layout.minimumWidth: 0
                            }
                            DText {
                                theme: root.theme; visible: root.pairedOverview
                                text: root.page === "Today" ? root.dayLabel(root.store.date) : "A place for what comes next."
                                color: root.theme.secondary; font.pixelSize: root.theme.small
                                Layout.fillWidth: true; Layout.minimumWidth: 0
                            }
                        }
                        RowLayout {
                            visible: root.page === "Today"
                            Layout.row: pageHeader.centeredDate ? 0 : 1
                            Layout.column: pageHeader.centeredDate ? 1 : 0
                            Layout.columnSpan: pageHeader.centeredDate ? 1 : 2
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: Infinity
                            Layout.fillWidth: false
                            spacing: root.theme.space(8)
                            DButton { theme: root.theme; quiet: true; text: "Previous day"; iconName: "previous"; objectName: "previousDay"; onClicked: root.store.date = root.offsetDay(root.store.date, -1) }
                            DateField {
                                id: dayPicker
                                theme: root.theme; today: root.store.today; text: root.store.date
                                caption: root.dayLabel(root.store.date); fieldName: "workspaceDate"; iconOnly: true
                                onTextEdited: { if (root.store.validDate(text, false)) root.store.date = text; }
                            }
                            DButton { theme: root.theme; quiet: true; text: "Next day"; iconName: "next"; objectName: "nextDay"; onClicked: root.store.date = root.offsetDay(root.store.date, 1) }
                        }
                        PinnedActivities {
                            workspace: root; visible: root.planPinsInHeader
                            Layout.row: 0; Layout.column: 1
                            Layout.preferredWidth: root.theme.space(340); Layout.maximumWidth: root.theme.space(340)
                        }
                        RowLayout {
                            Layout.row: 0; Layout.column: pageHeader.columns - 1
                            Layout.fillWidth: pageHeader.centeredDate
                            Layout.maximumWidth: Infinity
                            spacing: root.theme.space(8)
                            Item { visible: pageHeader.centeredDate; Layout.fillWidth: true }
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
                            TodayView { id: todayView; workspace: root; visible: root.store.loaded && root.page === "Today"; Layout.fillWidth: true }
                            PlanView { workspace: root; visible: root.store.loaded && root.page === "Plan"; Layout.fillWidth: true }
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
                            OverviewInsights {
                                theme: root.theme; summary: root.store.insights; activitiesById: root.store.activitiesById
                                visible: root.store.loaded && root.selectedId === "" && (root.pairedOverview || root.page === "History"); Layout.fillWidth: true
                                onActivityRequested: id => root.selectActivity(id)
                            }
                            Item { implicitHeight: root.theme.space(8) }
                        }
                    }
                    ActivityDetail {
                        id: detail
                        theme: root.theme; store: root.store; activityId: root.selectedId
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
                }
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
