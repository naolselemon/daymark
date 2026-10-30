import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Popup {
    id: root
    required property var theme
    required property var store
    property var captured: null
    property var selectedTaskIds: []
    readonly property var availableTasks: store.tasksForEntry(captured)
    property bool saving: false
    property bool dismissPending: false
    property bool writingExpanded: false
    property string baseline: ""
    property string requestId: ""
    property string payload: ""
    property string message: ""
    property string savedMessage: ""
    readonly property bool dateLocked: !!captured && (captured.source === "timer" || !!captured.startUtc || !!captured.endUtc)
    readonly property string fingerprint: JSON.stringify([dateField.text, noteField.text, selectedTaskIds])
    readonly property bool dirty: baseline !== "" && (baseline !== fingerprint || requestId !== "")
    onFingerprintChanged: if (dirty && !saving) savedMessage = "";
    signal saved(string message)
    signal expansionRequested(bool expanded)
    objectName: "sessionEditor"
    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    width: Math.min(parent ? parent.width : theme.space(440), theme.space(writingExpanded ? 860 : 720))
    height: parent ? parent.height : Math.min(implicitHeight, theme.space(680))
    implicitHeight: body.implicitHeight + padding * 2
    x: parent ? (parent.width - width) / 2 : 0
    y: 0
    padding: theme.space(12)
    background: Rectangle { color: root.theme.background; border.color: root.theme.border; radius: root.theme.radius }
    function begin(session) {
        if (opened || saving) return false;
        if (dirty) { open(); return false; }
        captured = JSON.parse(JSON.stringify(session));
        dateField.text = session.date;
        noteField.text = session.note || "";
        selectedTaskIds = (session.tasks || []).map(task => task.id);
        dismissPending = false;
        requestId = ""; payload = ""; message = ""; savedMessage = "";
        baseline = fingerprint;
        open();
        noteField.forceActiveFocus();
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
        requestId = ""; payload = ""; baseline = ""; dismissPending = false;
        close();
        return true;
    }
    function save() {
        if (!visible || saving || dismissPending || dateField.calendarOpen || !captured || !dirty) return;
        if (!dateLocked && !store.validDate(dateField.text.trim(), false)) {
            message = "Choose a date for this log.";
            dateField.forceActiveFocus();
            return;
        }
        // Omitted fields stay untouched, including historical timing and metadata.
        const fields = {expectedRevision: captured.revision, note: noteField.text, taskIds: selectedTaskIds};
        if (!dateLocked) fields.date = dateField.text.trim();
        const next = JSON.stringify(fields);
        if (payload !== next || !requestId) { payload = next; requestId = store.newRequestId(); }
        saving = true;
        savedMessage = "";
        message = "";
        store.updateSession(captured.id, fields, (ok, result, error) => {
            saving = false;
            if (!ok) { message = (error && error.message ? error.message : "Could not save this change.") + " Your draft is still here. Retry, or cancel to discard it."; return; }
            requestId = ""; payload = ""; baseline = fingerprint;
            savedMessage = "Changes saved." + (result && result.warning ? " " + result.warning : "");
            captured = store.sessions.find(session => session.id === captured.id) || captured;
            saved(savedMessage);
            if (result && result.warning) return;
            close();
        }, requestId);
    }
    Shortcut { sequences: ["Ctrl+Return", "Ctrl+Enter", "Ctrl+S"]; enabled: root.opened && root.visible && !root.saving && !root.dismissPending && !dateField.calendarOpen; onActivated: root.save() }
    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(8)
        Keys.onEscapePressed: event => { root.requestDismiss(); event.accepted = true; }
        RowLayout {
            Layout.fillWidth: true
            DButton { theme: root.theme; text: qsTr("Back"); iconName: "back"; quiet: true; enabled: !root.saving; onClicked: root.requestDismiss() }
            DText { theme: root.theme; text: qsTr("Edit entry"); font.pixelSize: root.theme.heading; font.bold: true; Layout.fillWidth: true }
            DButton {
                theme: root.theme; text: root.writingExpanded ? qsTr("Compact editor") : qsTr("Expand writing")
                iconName: root.writingExpanded ? "collapse" : "expand"; quiet: true; selected: root.writingExpanded
                objectName: "sessionExpand"; onClicked: root.expansionRequested(!root.writingExpanded)
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.preferredHeight: fields.implicitHeight
            Layout.minimumHeight: root.theme.space(60)
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: fields
                width: scroll.availableWidth
                spacing: root.theme.space(12)
                enabled: !root.saving && !root.dismissPending
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: "Date" }
                    DateField {
                        id: dateField
                        theme: root.theme
                        today: root.store.today
                        fieldName: "sessionDate"
                        Layout.fillWidth: true
                        visible: !root.dateLocked
                        enabled: !root.dateLocked
                    }
                    DText {
                        theme: root.theme
                        objectName: "sessionRecordedDate"
                        Layout.fillWidth: true
                        visible: root.dateLocked
                        text: Display.day(dateField.text, root.store.today)
                        color: root.theme.secondary
                    }
                }
                TaskSelector {
                    theme: root.theme
                    namePrefix: "sessionTaskChoice"
                    Layout.fillWidth: true
                    tasks: root.availableTasks
                    selectedIds: root.selectedTaskIds
                    onSelectionEdited: ids => root.selectedTaskIds = ids
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: qsTr("Entry · optional") }
                    DArea {
                        id: noteField
                        theme: root.theme
                        objectName: "sessionNote"
                        Accessible.name: qsTr("Log entry")
                        placeholderText: "Anything you want to remember"
                        textFormat: TextEdit.PlainText
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(implicitHeight, root.theme.space(root.writingExpanded ? 320 : 160))
                    }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        DText { theme: root.theme; objectName: "sessionSaved"; Layout.fillWidth: true; visible: text !== ""; text: root.savedMessage; color: root.theme.accent }
        DText { theme: root.theme; objectName: "sessionFeedback"; Layout.fillWidth: true; visible: text !== ""; text: root.message; color: root.theme.urgent }
        ColumnLayout {
            visible: root.dismissPending
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            DText { theme: root.theme; text: "Discard these changes?"; Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                DButton {
                    id: keepEditing
                    theme: root.theme
                    objectName: "sessionKeepEditing"
                    text: "Keep editing"
                    onClicked: { root.dismissPending = false; noteField.forceActiveFocus(); }
                }
                DButton {
                    theme: root.theme
                    objectName: "sessionConfirmDiscard"
                    quiet: true
                    text: "Discard changes"
                    onClicked: root.discardChanges()
                }
            }
        }
        RowLayout {
            visible: !root.dismissPending
            Layout.fillWidth: true
            DButton { theme: root.theme; objectName: "sessionDiscard"; quiet: true; text: root.dirty ? "Cancel" : "Close"; iconName: "close"; enabled: !root.saving; onClicked: root.requestDismiss() }
            Item { Layout.fillWidth: true }
            DButton {
                theme: root.theme
                objectName: "sessionSave"
                text: root.saving ? "Saving…" : root.requestId ? "Retry save" : "Save changes"
                iconName: "save"
                primary: true
                iconOnly: false
                enabled: !root.saving && root.dirty && root.store.loaded
                onClicked: root.save()
                shortcutHint: "Ctrl+S · Ctrl+Enter"
            }
        }
    }
}
