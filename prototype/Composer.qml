pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Popup {
    id: root
    required property var theme
    required property var store
    property string mode: "plan"
    property string activityId: ""
    property string errorMessage: ""
    property string statusMessage: ""
    property bool markDone: false
    property bool choosingExisting: false
    property bool saving: false
    property bool dismissPending: false
    property bool pickerExpanded: false
    property string draftBaseline: ""
    property string pendingRequestId: ""
    property string pendingPayload: ""
    readonly property bool existing: mode === "log" && choosingExisting && activityId !== ""
    readonly property string draftFingerprint: JSON.stringify({
        mode: mode, activityId: activityId, choosingExisting: choosingExisting,
        title: titleField.text, date: dateField.text, note: noteField.text, done: markDone
    })
    readonly property bool dirty: draftBaseline !== "" && (draftFingerprint !== draftBaseline || pendingRequestId !== "")
    readonly property var matchingActivities: {
        const query = activitySearch.text.trim().toLocaleLowerCase();
        return store.activities.filter(activity => !query
            || [activity.title, activity.id].join(" ").toLocaleLowerCase().includes(query));
    }
    signal accepted(string activityId)
    signal saved()

    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    width: Math.min(theme.space(560), parent ? parent.width - theme.space(24) : theme.space(560))
    height: Math.min(implicitHeight, parent ? parent.height - theme.space(24) : 600)
    implicitHeight: body.implicitHeight + topPadding + bottomPadding
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? (parent.height - height) / 2 : 0
    padding: theme.space(24)
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

    function requestDismiss() {
        if (saving) return false;
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
        if (saving) return;
        activityId = id;
        choosingExisting = true;
        markDone = false;
        pickerExpanded = false;
        dateField.forceActiveFocus();
    }

    function selectMode(nextMode) {
        if (saving) return;
        mode = nextMode;
        if (mode === "plan") {
            choosingExisting = false;
            activityId = "";
        }
    }

    onDirtyChanged: {
        if (dirty) statusMessage = "";
    }

    Component.onCompleted: resetDraft("plan", "")

    function submit() {
        if (!visible || saving || dismissPending || dateField.calendarOpen) return;
        errorMessage = "";
        statusMessage = "";
        if (mode === "log" && choosingExisting && !existing) {
            errorMessage = "Choose an activity, or start a new one.";
            activitySearch.forceActiveFocus();
            return;
        }
        if (!existing && !titleField.text.trim()) {
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
        const fields = existing
            ? {date: date, note: noteField.text, done: markDone}
            : {title: titleField.text.trim(), plannedFor: mode === "plan" ? date : "",
                note: mode === "plan" ? noteField.text : "", mode: mode, date: date,
                sessionNote: mode === "log" ? noteField.text : "", done: mode === "log" && markDone};
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
            draftBaseline = draftFingerprint;
            statusMessage = (mode === "plan" ? "Plan saved." : markDone ? "Activity logged and marked done." : "Activity logged.")
                + (result && result.warning ? " " + result.warning : "");
            close();
            accepted(result.activityId);
            saved();
        };
        if (existing)
            store.addSession(activityId, fields, finished, pendingRequestId);
        else
            store.createActivity(fields, finished, pendingRequestId);
    }

    Shortcut {
        sequences: ["Ctrl+S", "Ctrl+Return", "Ctrl+Enter"]
        enabled: root.opened && root.visible && !root.saving && !root.dismissPending && !dateField.calendarOpen
        onActivated: root.submit()
    }

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(24)
        Keys.onEscapePressed: event => { root.requestDismiss(); event.accepted = true; }
        DText {
            theme: root.theme
            Layout.fillWidth: true
            text: root.mode === "plan" ? "Plan an activity" : "Log an activity"
            font.pixelSize: root.theme.title
            font.bold: true
        }
        RowLayout {
            enabled: !root.saving && !root.dismissPending
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
                spacing: root.theme.space(16)
                enabled: !root.saving && !root.dismissPending
                RowLayout {
                    visible: root.mode === "log"
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
                    visible: root.existing && !root.pickerExpanded
                    quiet: true
                    text: "Change activity"
                    onClicked: { root.pickerExpanded = true; activitySearch.forceActiveFocus(); }
                }
                ColumnLayout {
                    visible: !root.choosingExisting
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: "Activity" }
                    DField {
                        id: titleField
                        theme: root.theme
                        objectName: "composerTitle"
                        Accessible.name: "Activity title"
                        Layout.fillWidth: true
                        placeholderText: root.mode === "plan" ? "What would you like to do?" : "What did you do?"
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: root.mode === "plan" ? "Planned for" : "Date" }
                    DateField {
                        id: dateField
                        theme: root.theme
                        today: root.store.today
                        fieldName: "composerDate"
                        allowEmpty: root.mode === "plan"
                        Layout.fillWidth: true
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: "Note · optional" }
                    DArea {
                        id: noteField
                        theme: root.theme
                        objectName: root.mode === "plan" ? "composerActivityNote" : "composerNote"
                        Accessible.name: "Note, optional"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(implicitHeight, root.theme.space(100))
                        textFormat: TextEdit.PlainText
                        placeholderText: "Anything you want to remember"
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
        DText {
            theme: root.theme
            objectName: "composerError"
            Layout.fillWidth: true
            visible: text !== ""
            text: root.errorMessage
            color: root.theme.urgent
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
                text: "Cancel"
                quiet: true
                enabled: !root.saving
                onClicked: root.requestDismiss()
            }
            Item { Layout.fillWidth: true }
            DButton {
                theme: root.theme
                objectName: "composerSubmit"
                primary: true
                enabled: !root.saving && root.store.loaded
                text: root.saving ? "Saving…" : root.pendingRequestId && root.errorMessage !== "" ? "Retry save"
                    : root.mode === "plan" ? "Save plan" : "Save log"
                onClicked: root.submit()
                shortcutHint: "Ctrl+S · Ctrl+Enter"
            }
        }
    }
}
