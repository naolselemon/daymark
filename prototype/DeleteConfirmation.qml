import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    required property var store
    property string kind: ""
    property string recordId: ""
    property string title: ""
    property int revision: 0
    property string requestId: ""
    property bool saving: false
    property string message: ""
    readonly property bool permanent: kind === "purge"
    signal deleted(string kind, string recordId)
    objectName: "deleteDialog"
    modal: true; focus: true; closePolicy: Popup.NoAutoClose
    anchors.centerIn: parent
    width: Math.min(parent.width - theme.space(32), theme.space(500))
    height: Math.min(parent.height - theme.space(32), implicitHeight)
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(24)
    background: Rectangle { color: root.theme.background; border.color: root.theme.border; radius: root.theme.radius }
    function begin(kind, id, revision, title) {
        if (opened) return;
        root.kind = kind; root.recordId = id; root.revision = revision; root.title = title;
        requestId = store.newRequestId(); message = ""; confirmation.text = "";
        open(); cancelButton.forceActiveFocus();
    }
    function requestDismiss() { if (saving) return false; close(); return true; }
    function submit() {
        if (saving || (permanent && confirmation.text !== "DELETE")) return;
        saving = true;
        const finished = (ok, result, error) => {
            saving = false;
            if (!ok) { message = error && error.message ? error.message : "Could not delete. Try again."; return; }
            deleted(kind, recordId); close();
        };
        if (permanent) store.purgeDeleted(recordId, finished, requestId);
        else store.deleteRecord(kind, recordId, revision, finished, requestId);
    }
    Shortcut { sequence: "Escape"; enabled: root.opened; onActivated: root.requestDismiss() }
    contentItem: ColumnLayout {
        id: body; spacing: root.theme.space(18)
        DText { theme: root.theme; text: root.permanent ? "Delete permanently?" : "Delete this entry?"; font.pixelSize: root.theme.title; Layout.fillWidth: true }
        ScrollView {
            id: scroll; Layout.fillWidth: true; Layout.fillHeight: true
            Layout.preferredHeight: description.implicitHeight; Layout.minimumHeight: root.theme.space(40)
            contentWidth: availableWidth; clip: true; ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: description; width: scroll.availableWidth; spacing: root.theme.space(14)
                DText { theme: root.theme; objectName: "deleteRecordName"; text: root.title || "Journal entry"; Layout.fillWidth: true }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.permanent ? root.theme.urgent : root.theme.secondary
                    text: root.permanent ? "This cannot be undone. Related entries are removed too. Older exports and backups are unchanged. Type DELETE to confirm."
                        : (root.kind === "note" ? "You can restore it from Diary → Recently deleted." : "You can restore it from History → Recently deleted.") + (root.kind === "activity" ? " Its entries will move with it." : "")
                }
                DField { id: confirmation; theme: root.theme; objectName: "purgeConfirmation"; visible: root.permanent; Accessible.name: "Type DELETE to confirm"; Layout.fillWidth: true }
                DText { theme: root.theme; objectName: "deleteFeedback"; text: root.message; visible: text !== ""; color: root.theme.urgent; Layout.fillWidth: true }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            DButton { id: cancelButton; theme: root.theme; objectName: "deleteCancel"; text: "Keep entry"; primary: true; enabled: !root.saving; onClicked: root.requestDismiss() }
            Item { Layout.fillWidth: true }
            DButton { theme: root.theme; quiet: true; objectName: "deleteConfirm"; text: root.saving ? "Deleting…" : "Delete"; enabled: !root.saving && (!root.permanent || confirmation.text === "DELETE"); onClicked: root.submit() }
        }
    }
}
