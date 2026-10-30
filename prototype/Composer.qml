pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Popup {
    id: root
    required property var theme
    required property var store
    property var countdown: null
    property string countdownRunId: ""
    property var selectedTaskIds: []
    readonly property bool countdownPending: countdownRunId !== "" && !!countdown
        && countdown.runId === countdownRunId && (countdown.logPending || countdown.logSaved)
    readonly property var availableTasks: existing && store.activity(activityId)
        ? store.activity(activityId).tasks || [] : []
    property string mode: "plan"
    property string activityId: ""
    property string errorMessage: ""
    property string statusMessage: ""
    property bool markDone: false
    property bool choosingExisting: false
    property bool saving: false
    property bool dismissPending: false
    property bool pickerExpanded: false
    property bool writingExpanded: false
    property string draftBaseline: ""
    property string pendingRequestId: ""
    property string pendingPayload: ""
    readonly property bool existing: mode === "log" && choosingExisting && activityId !== ""
    readonly property string draftFingerprint: JSON.stringify({
        mode: mode, activityId: activityId, choosingExisting: choosingExisting,
        title: titleField.text, date: dateField.text, note: noteField.text, done: markDone,
        tasks: mode === "plan" ? taskEditor.fingerprint : selectedTaskIds, runId: countdownRunId
    })
    readonly property bool dirty: draftBaseline !== "" && (draftFingerprint !== draftBaseline || pendingRequestId !== "")
    readonly property var matchingActivities: {
        const query = activitySearch.text.trim().toLocaleLowerCase();
        return store.activities.filter(activity => !query
            || [activity.title, activity.id].join(" ").toLocaleLowerCase().includes(query));
    }
    signal accepted(string activityId)
    signal saved()
    signal expansionRequested(bool expanded)

    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    width: Math.min(theme.space(writingExpanded ? 860 : 720), parent ? parent.width : theme.space(440))
    height: parent ? parent.height : Math.min(implicitHeight, theme.space(680))
    implicitHeight: body.implicitHeight + topPadding + bottomPadding
    x: parent ? (parent.width - width) / 2 : 0
    y: 0
    padding: theme.space(12)
    background: Rectangle {
        color: root.theme.background
        border.color: root.theme.border
        radius: root.theme.radius
    }

    function resetDraft(nextMode, id) {
        activityId = id;
        choosingExisting = id !== "";
        mode = id ? "log" : nextMode;
        titleField.text = "";
        dateField.text = store.date;
        noteField.text = "";
        markDone = false;
        countdownRunId = "";
        selectedTaskIds = [];
        taskEditor.load([]);
        dismissPending = false;
        pickerExpanded = false;
        activitySearch.text = "";
        errorMessage = "";
        statusMessage = "";
        pendingRequestId = "";
        pendingPayload = "";
        draftBaseline = draftFingerprint;
    }

    function begin(nextMode, id = "") {
        if (saving || dirty) {
            open();
            return false;
        }
        resetDraft(nextMode, id);
        open();
        if (existing) dateField.forceActiveFocus();
        else titleField.forceActiveFocus();
        return true;
    }

    function beginLogTask(id, taskId, date) {
        if (!begin("log", id)) return false;
        selectedTaskIds = taskId ? [taskId] : [];
        if (date) dateField.text = date;
        draftBaseline = draftFingerprint;
        return true;
    }

    function beginCountdown(id, taskId, runId, date) {
        if (!beginLogTask(id, taskId, date)) return false;
        countdownRunId = runId;
        if (countdown && countdown.logPending && countdown.logPayload) {
            const payload = countdown.logPayload;
            activityId = payload.activityId;
            selectedTaskIds = payload.taskIds || [];
            dateField.text = payload.date;
            noteField.text = payload.note || "";
            markDone = !!payload.done;
        }
        draftBaseline = draftFingerprint;
        return true;
    }

    function requestDismiss() {
        if (saving || dateField.calendarOpen) return false;
        if (!dirty) { close(); return true; }
        dismissPending = true;
        keepEditing.forceActiveFocus();
        return false;
    }

    function discardChanges() {
        if (saving) return false;
        resetDraft("plan", "");
        close();
        return true;
    }

    function selectActivity(id) {
        if (saving || countdownRunId !== "") return;
        activityId = id;
        choosingExisting = true;
        markDone = false;
        selectedTaskIds = [];
        pickerExpanded = false;
        dateField.forceActiveFocus();
    }

    function selectMode(nextMode) {
        if (saving || countdownRunId !== "") return;
        mode = nextMode;
        if (mode === "plan") {
            choosingExisting = false;
            activityId = "";
        }
    }

    function handlePlanEnter(event, nextField) {
        if (mode !== "plan" || (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
                || (event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return;
        event.accepted = true;
        if (event.isAutoRepeat || saving || dismissPending || dateField.calendarOpen) return;
        if (nextField) nextField.forceActiveFocus(Qt.TabFocusReason);
        else submit();
    }

    onDirtyChanged: {
        if (dirty) statusMessage = "";
    }

    Component.onCompleted: resetDraft("plan", "")

    function submit() {
        if (!visible || saving || dismissPending || dateField.calendarOpen) return;
        errorMessage = "";
        statusMessage = "";
        if (countdownRunId !== "" && !countdown) {
            errorMessage = qsTr("The countdown is unavailable. Your draft is still here.");
            return;
        }
        if (countdownRunId === "" && mode === "log" && choosingExisting && !existing) {
            errorMessage = "Choose an activity, or start a new one.";
            activitySearch.forceActiveFocus();
            return;
        }
        if (countdownRunId === "" && !existing && !titleField.text.trim()) {
            errorMessage = "Enter a title. Your draft is still here.";
            titleField.forceActiveFocus();
            return;
        }
        const date = dateField.text.trim();
        if (!store.validDate(date, mode === "plan")) {
            errorMessage = mode === "plan" ? "Choose a date, or choose No date for Inbox." : "Choose a date for this log.";
            dateField.forceActiveFocus();
            return;
        }
        const fields = existing || countdownRunId !== ""
            ? {date: date, note: noteField.text, done: markDone, taskIds: selectedTaskIds}
            : {title: titleField.text.trim(), plannedFor: mode === "plan" ? date : "",
                note: mode === "plan" ? noteField.text : "", mode: mode, date: date,
                sessionNote: mode === "log" ? noteField.text : "", done: mode === "log" && markDone};
        if (mode === "plan") fields.tasks = taskEditor.tasks;
        const payload = JSON.stringify({op: existing ? "add_session" : "create_activity",
            activityId: existing ? activityId : "", fields: fields});
        if (payload !== pendingPayload || !pendingRequestId) {
            pendingRequestId = store.newRequestId();
            pendingPayload = payload;
        }
        saving = true;
        const finished = function(ok, result, error) {
            saving = false;
            if (!ok) {
                errorMessage = (error && error.message ? error.message : "Could not save this change.")
                    + " Your draft is still here. Try saving again.";
                return;
            }
            pendingRequestId = "";
            pendingPayload = "";
            if (mode === "plan") {
                titleField.text = "";
                noteField.text = "";
                markDone = false;
                taskEditor.load([]);
            }
            draftBaseline = draftFingerprint;
            statusMessage = (mode === "plan" ? "Plan added. Add another, or choose Done."
                : markDone ? "Activity logged and marked done." : "Activity logged.")
                + (result && result.warning ? " " + result.warning : "");
            if (mode !== "plan") close();
            accepted(result.activityId);
            saved();
            if (mode === "plan") titleField.forceActiveFocus(Qt.TabFocusReason);
        };
        if (countdownRunId !== "" && countdown)
            countdown.saveEntry(Object.assign({}, fields, {activityId: activityId, runId: countdownRunId}), finished);
        else if (existing)
            store.addSession(activityId, fields, finished, pendingRequestId);
        else
            store.createActivity(fields, finished, pendingRequestId);
    }

    Shortcut {
        sequences: ["Ctrl+S", "Ctrl+Return", "Ctrl+Enter"]
        autoRepeat: false
        enabled: root.opened && root.visible && !root.saving && !root.dismissPending && !dateField.calendarOpen
        onActivated: root.submit()
    }

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(8)
        Keys.onEscapePressed: event => { root.requestDismiss(); event.accepted = true; }
        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            DButton {
                theme: root.theme; text: qsTr("Back"); iconName: "back"; quiet: true
                objectName: "composerBack"; enabled: !root.saving
                onClicked: root.requestDismiss()
            }
            DText {
                theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                text: root.mode === "plan" ? qsTr("Plan activities") : qsTr("Log an activity")
                font.pixelSize: root.theme.heading; font.bold: true
            }
            DButton {
                theme: root.theme; text: root.writingExpanded ? qsTr("Compact editor") : qsTr("Expand writing")
                iconName: root.writingExpanded ? "collapse" : "expand"; quiet: true
                objectName: "composerExpand"; selected: root.writingExpanded
                onClicked: root.expansionRequested(!root.writingExpanded)
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        RowLayout {
            enabled: !root.saving && !root.dismissPending && root.countdownRunId === ""
            Layout.fillWidth: true
            DButton {
                theme: root.theme
                objectName: "composerModePlan"
                text: "Plan"
                selected: root.mode === "plan"
                onClicked: root.selectMode("plan")
            }
            DButton {
                theme: root.theme
                objectName: "composerModeLog"
                text: "Log"
                selected: root.mode === "log"
                onClicked: root.selectMode("log")
            }
            Item { Layout.fillWidth: true }
            DText {
                theme: root.theme; visible: root.mode === "plan" && root.width >= root.theme.space(540)
                text: qsTr("Add another after saving"); color: root.theme.secondary; font.pixelSize: root.theme.small
            }
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: fields.implicitHeight
            Layout.minimumHeight: root.theme.space(60)
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: fields
                width: scroll.availableWidth
                spacing: root.theme.space(12)
                enabled: !root.saving && !root.dismissPending && !root.countdownPending
                RowLayout {
                    visible: root.mode === "log" && root.countdownRunId === ""
                    Layout.fillWidth: true
                    DButton {
                        theme: root.theme
                        objectName: "composerNewActivity"
                        text: "New activity instead"
                        quiet: true
                        visible: root.choosingExisting
                        onClicked: {
                            root.choosingExisting = false;
                            root.activityId = "";
                            root.markDone = false;
                            root.selectedTaskIds = [];
                            titleField.forceActiveFocus();
                        }
                    }
                    DButton {
                        theme: root.theme
                        objectName: "composerExistingActivity"
                        text: "Use an existing activity"
                        quiet: true
                        visible: !root.choosingExisting
                        onClicked: {
                            root.choosingExisting = true;
                            root.markDone = false;
                            root.pickerExpanded = true;
                            activitySearch.forceActiveFocus();
                        }
                    }
                }
                ColumnLayout {
                    visible: root.mode === "log" && root.choosingExisting && (!root.existing || root.pickerExpanded)
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: "Choose an activity" }
                    DField {
                        id: activitySearch
                        theme: root.theme
                        objectName: "composerActivitySearch"
                        Layout.fillWidth: true
                        placeholderText: "Find an activity"
                        Accessible.name: "Search existing activities"
                    }
                    ListView {
                        id: activityList
                        objectName: "composerActivityList"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentHeight, root.theme.space(170))
                        clip: true
                        spacing: root.theme.space(4)
                        model: root.matchingActivities
                        ScrollBar.vertical: ScrollBar {}
                        delegate: DButton {
                            id: activityChoice
                            required property var modelData
                            theme: root.theme
                            objectName: "composerActivityChoice-" + modelData.id
                            width: activityList.width
                            quiet: true
                            selected: root.activityId === modelData.id
                            text: modelData.title
                            contentItem: ColumnLayout {
                                spacing: root.theme.space(4)
                                DText {
                                    theme: root.theme
                                    Layout.fillWidth: true
                                    text: activityChoice.text
                                    color: activityChoice.selected ? root.theme.accent : root.theme.foreground
                                }
                                DText {
                                    theme: root.theme
                                    Layout.fillWidth: true
                                    text: activityChoice.modelData.status === "done" ? "Done"
                                        : activityChoice.modelData.plannedFor
                                            ? Display.day(activityChoice.modelData.plannedFor, root.store.today) : "Open"
                                    font.pixelSize: root.theme.small
                                    color: root.theme.secondary
                                }
                            }
                            onClicked: root.selectActivity(modelData.id)
                        }
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        visible: root.matchingActivities.length === 0
                        text: "No activities found. Try another search or start a new one."
                        color: root.theme.secondary
                    }
                }
                DText {
                    theme: root.theme
                    visible: root.existing && !root.pickerExpanded
                    Layout.fillWidth: true
                    text: root.existing && root.store.activity(root.activityId)
                        ? root.store.activity(root.activityId).title : ""
                    font.bold: true
                }
                DButton {
                    theme: root.theme
                    objectName: "composerChangeActivity"
                    iconName: "search"
                    visible: root.existing && !root.pickerExpanded && root.countdownRunId === ""
                    quiet: true
                    text: "Change activity"
                    onClicked: { root.pickerExpanded = true; activitySearch.forceActiveFocus(); }
                }
                ColumnLayout {
                    visible: !root.choosingExisting
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(12)
                        DText { theme: root.theme; text: "Activity"; font.bold: true }
                        DText {
                            theme: root.theme
                            Layout.fillWidth: true
                            visible: root.mode === "plan" && root.width >= root.theme.space(600)
                            text: "Enter: next"
                            color: root.theme.secondary
                            font.pixelSize: root.theme.small
                            font.italic: true
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                    DField {
                        id: titleField
                        theme: root.theme
                        objectName: "composerTitle"
                        Accessible.name: "Activity title"
                        Accessible.description: root.mode === "plan" ? "Enter moves to the planned date." : ""
                        Layout.fillWidth: true
                        placeholderText: root.mode === "plan" ? "What would you like to do?" : "What did you do?"
                        Keys.onPressed: event => root.handlePlanEnter(event, dateField)
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(12)
                        DText { theme: root.theme; text: root.mode === "plan" ? "Planned for" : "Date"; font.bold: true }
                        DText {
                            theme: root.theme
                            Layout.fillWidth: true
                            visible: root.mode === "plan" && root.width >= root.theme.space(600)
                            text: "Space: calendar · Enter: next"
                            color: root.theme.secondary
                            font.pixelSize: root.theme.small
                            font.italic: true
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                    DateField {
                        id: dateField
                        theme: root.theme
                        today: root.store.today
                        fieldName: "composerDate"
                        allowEmpty: root.mode === "plan"
                        advanceOnEnter: root.mode === "plan"
                        onAccepted: {
                            if (!root.saving && !root.dismissPending && !calendarOpen)
                                noteField.forceActiveFocus(Qt.TabFocusReason);
                        }
                        Layout.fillWidth: true
                    }
                }
                TaskEditor {
                    id: taskEditor
                    theme: root.theme
                    namePrefix: "composerTask"
                    visible: root.mode === "plan"
                    Layout.fillWidth: true
                }
                TaskSelector {
                    theme: root.theme
                    namePrefix: "composerTaskChoice"
                    tasks: root.availableTasks
                    selectedIds: root.selectedTaskIds
                    visible: root.mode === "log" && tasks.length > 0
                    Layout.fillWidth: true
                    onSelectionEdited: ids => root.selectedTaskIds = ids
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(12)
                        DText { theme: root.theme; text: root.mode === "plan" ? qsTr("Description · optional") : qsTr("Entry · optional"); font.bold: true }
                        DText {
                            theme: root.theme
                            Layout.fillWidth: true
                            visible: root.mode === "plan" && root.width >= root.theme.space(600)
                            text: "Enter: next · Shift+Enter: new line"
                            color: root.theme.secondary
                            font.pixelSize: root.theme.small
                            font.italic: true
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                    DArea {
                        id: noteField
                        theme: root.theme
                        objectName: root.mode === "plan" ? "composerActivityNote" : "composerNote"
                        Accessible.name: root.mode === "plan" ? qsTr("Description, optional") : qsTr("Entry, optional")
                        Accessible.description: root.mode === "plan" ? "Enter moves to Add plan. Shift+Enter inserts a new line." : ""
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(implicitHeight, root.theme.space(root.writingExpanded ? 300 : 104))
                        textFormat: TextEdit.PlainText
                        placeholderText: "Anything you want to remember"
                        Keys.onPressed: event => root.handlePlanEnter(event, submitButton)
                    }
                }
                DCheckBox {
                    theme: root.theme
                    visible: root.mode === "log"
                    objectName: "composerMarkDone"
                    text: "Mark this activity done"
                    checked: root.markDone
                    onToggled: root.markDone = checked
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        DText {
            theme: root.theme
            objectName: "composerCountdownPending"
            Layout.fillWidth: true
            visible: root.countdownPending
            text: qsTr("This timer entry is awaiting confirmation. Retry the same entry; its fields are kept unchanged.")
            color: root.theme.secondary
        }
        DText {
            theme: root.theme
            objectName: "composerError"
            Layout.fillWidth: true
            visible: text !== ""
            text: root.errorMessage
            color: root.theme.urgent
        }
        DText {
            theme: root.theme
            objectName: "composerStatus"
            Layout.fillWidth: true
            visible: text !== ""
            text: root.statusMessage
            color: root.theme.accent
        }
        ColumnLayout {
            visible: root.dismissPending
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            DText { theme: root.theme; text: "Discard this draft?"; Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                DButton {
                    id: keepEditing
                    theme: root.theme
                    objectName: "composerKeepEditing"
                    text: "Keep editing"
                    onClicked: { root.dismissPending = false; noteField.forceActiveFocus(); }
                }
                DButton {
                    theme: root.theme
                    objectName: "composerConfirmDiscard"
                    quiet: true
                    text: "Discard draft"
                    onClicked: root.discardChanges()
                }
            }
        }
        RowLayout {
            visible: !root.dismissPending
            Layout.fillWidth: true
            DButton {
                theme: root.theme
                objectName: "composerDiscard"
                text: root.mode === "plan" ? "Done" : "Cancel"
                iconName: "close"
                quiet: true
                enabled: !root.saving
                onClicked: root.requestDismiss()
            }
            Item { Layout.fillWidth: true }
            DButton {
                id: submitButton
                theme: root.theme
                objectName: "composerSubmit"
                iconName: root.mode === "plan" ? "add" : "save"
                primary: true
                iconOnly: false
                enabled: !root.saving && root.store.loaded
                text: root.saving ? "Saving…" : (root.countdownPending || (root.pendingRequestId && root.errorMessage !== "")) ? "Retry save"
                    : root.mode === "plan" ? "Add plan" : qsTr("Save entry")
                onClicked: root.submit()
                shortcutHint: "Ctrl+S · Ctrl+Enter"
                Keys.onPressed: event => root.handlePlanEnter(event, null)
            }
        }
    }
}
