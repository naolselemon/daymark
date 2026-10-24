import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Popup {
    id: root
    required property var theme
    required property var store
    property var captured: null
    property bool saving: false
    property bool dismissPending: false
    property string baseline: ""
    property string requestId: ""
    property string payload: ""
    property string message: ""
    property string savedMessage: ""
    readonly property bool dateLocked: !!captured && (captured.source === "timer" || !!captured.startUtc || !!captured.endUtc)
    readonly property string fingerprint: JSON.stringify([dateField.text, noteField.text])
    readonly property bool dirty: baseline !== "" && (baseline !== fingerprint || requestId !== "")
    onFingerprintChanged: if (dirty && !saving) savedMessage = "";
    signal saved(string message)
    objectName: "sessionEditor"
    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    width: Math.min(parent ? parent.width - theme.space(24) : theme.space(560), theme.space(560))
    height: Math.min(parent ? parent.height - theme.space(24) : implicitHeight, implicitHeight)
    implicitHeight: body.implicitHeight + padding * 2
    anchors.centerIn: parent
    padding: theme.space(24)
    background: Rectangle { color: root.theme.background; border.color: root.theme.border; radius: root.theme.radius }
    function begin(session) {
        if (opened || saving) return false;
        if (dirty) { open(); return false; }
        captured = JSON.parse(JSON.stringify(session));
        dateField.text = session.date;
        noteField.text = session.note || "";
        dismissPending = false;
        requestId = ""; payload = ""; message = ""; savedMessage = "";
        baseline = fingerprint;
        open();
        noteField.forceActiveFocus();
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
        requestId = ""; payload = ""; baseline = ""; dismissPending = false;
        close();
        return true;
    }
    function save() {
        if (!visible || saving || dismissPending || !captured || !dirty) return;
        if (!dateLocked && !store.validDate(dateField.text.trim(), false)) {
            message = "Choose a date for this log.";
            dateField.forceActiveFocus();
            return;
        }
        // Omitted fields stay untouched, including historical timing and metadata.
        const fields = {expectedRevision: captured.revision, note: noteField.text};
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
        spacing: root.theme.space(24)
        Keys.onEscapePressed: event => { root.requestDismiss(); event.accepted = true; }
        DText { theme: root.theme; text: "Edit log"; font.pixelSize: root.theme.title; font.bold: true; Layout.fillWidth: true }
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
                spacing: root.theme.space(16)
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
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: "Note · optional" }
                    DArea {
                        id: noteField
                        theme: root.theme
                        objectName: "sessionNote"
                        Accessible.name: "Log note"
                        placeholderText: "Anything you want to remember"
                        textFormat: TextEdit.PlainText
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(implicitHeight, root.theme.space(120))
                    }
                }
            }
        }
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
                enabled: !root.saving && root.dirty && root.store.loaded
                onClicked: root.save()
                shortcutHint: "Ctrl+S · Ctrl+Enter"
            }
        }
    }
}
