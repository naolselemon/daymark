pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Dialogs

Popup {
    id: root
    required property var theme
    required property var store
    property bool saving: false
    property string message: ""
    property bool failed: false
    property string requestId: ""
    property string pendingPayload: ""
    property string exportPath: ""
    property string restorePath: ""
    property bool dismissPending: false
    readonly property string pendingAction: pendingPayload ? JSON.parse(pendingPayload)[0] : ""
    readonly property bool dirty: exportPath !== "" || restorePath !== "" || requestId !== ""
    readonly property bool choosingFile: exportPicker.visible || restorePicker.visible
    objectName: "dataSafetyDialog"
    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    width: Math.min(parent.width - theme.padding * 2, theme.space(560))
    height: Math.min(parent.height - theme.padding * 2, implicitHeight)
    implicitHeight: body.implicitHeight + padding * 2
    anchors.centerIn: parent
    padding: theme.space(24)
    background: Rectangle {
        color: root.theme.background
        border.color: root.theme.border
        radius: root.theme.radius
    }

    function begin() {
        if (opened) return;
        if (!dirty) { message = ""; failed = false; }
        dismissPending = false;
        open();
    }
    function requestDismiss() {
        if (saving || choosingFile) return false;
        if (dirty) {
            dismissPending = true;
            keepEditing.forceActiveFocus();
            return false;
        }
        close();
        return true;
    }
    function discard() {
        if (saving || choosingFile) return;
        exportPath = "";
        restorePath = "";
        requestId = "";
        pendingPayload = "";
        message = "";
        failed = false;
        dismissPending = false;
        close();
    }
    function run(action, args, operation) {
        if (saving || choosingFile) return;
        const next = JSON.stringify([action, args]);
        if (requestId && pendingPayload !== next) {
            message = "Retry the same action, or choose “Stop retrying” before changing it. The earlier action may already have completed.";
            failed = true;
            return;
        }
        if (!requestId) {
            pendingPayload = next;
            requestId = store.newRequestId();
        }
        saving = true;
        failed = false;
        dismissPending = false;
        message = action === "export" ? "Exporting your journal…" : "Importing your journal…";
        operation((ok, result, error) => {
            saving = false;
            failed = !ok;
            if (!ok) {
                message = (error && error.message ? error.message : "Could not finish.")
                    + " Your file selection is kept. Retry the same action to safely recover its result.";
                return;
            }
            requestId = "";
            pendingPayload = "";
            if (action === "export") {
                message = "JSON archive saved to " + (result && result.path ? result.path : args[1]);
                exportPath = "";
            } else {
                message = "Journal imported from " + args[0] + ".";
                restorePath = "";
            }
        }, requestId);
    }
    function localPath(fileUrl) {
        // Decode the URL pathname once: encoded #, % and Unicode belong to the filename.
        const match = /^file:\/\/(?:localhost)?(\/[^?#]*)$/i.exec(fileUrl.toString());
        if (!match) {
            failed = true;
            message = "Choose a file on this computer.";
            return "";
        }
        try { return decodeURIComponent(match[1]); }
        catch (error) {
            failed = true;
            message = "This file path could not be read. Choose the file again.";
            return "";
        }
    }
    function filename(path) { return path.slice(path.lastIndexOf("/") + 1); }
    function exportFile() {
        if (saving || choosingFile || (requestId && pendingAction !== "export")) return;
        dismissPending = false;
        if (!exportPath) { exportPicker.open(); return; }
        const path = exportPath;
        run("export", ["json", path], (cb, id) => store.exportRecords("json", path, cb, id));
    }
    function importFile() {
        if (!restorePath) return;
        const path = restorePath;
        run("restore", [path], (cb, id) => store.restoreRecords(path, cb, id));
    }

    FileDialog {
        id: exportPicker
        objectName: "exportFileDialog"
        title: "Export Daymark JSON — choose a new file"
        fileMode: FileDialog.SaveFile
        nameFilters: ["Daymark JSON archive (*.json)"]
        defaultSuffix: "json"
        onAccepted: {
            const path = root.localPath(selectedFile);
            if (!path) return;
            root.exportPath = path;
            // The native window can still report visible while accepting its selection.
            Qt.callLater(() => root.exportFile());
        }
    }
    FileDialog {
        id: restorePicker
        objectName: "restoreFileDialog"
        title: "Choose a Daymark JSON archive"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Daymark JSON archive (*.json)"]
        onAccepted: {
            const path = root.localPath(selectedFile);
            if (!path) return;
            root.restorePath = path;
            root.dismissPending = false;
            importButton.forceActiveFocus();
        }
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.opened && !root.choosingFile
        onActivated: root.requestDismiss()
    }

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(24)
        DText {
            theme: root.theme
            text: "Data & Safety"
            font.pixelSize: root.theme.title
            Layout.fillWidth: true
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: sections.implicitHeight
            Layout.minimumHeight: root.theme.space(40)
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: sections
                width: scroll.availableWidth
                spacing: root.theme.space(24)
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(12)
                    DText { theme: root.theme; text: "Export your journal"; font.bold: true; Layout.fillWidth: true }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "Save a complete JSON backup, including private notes and deleted entries."
                        color: root.theme.secondary
                    }
                    DButton {
                        theme: root.theme
                        objectName: "exportJson"
                        text: root.pendingAction === "export" ? "Retry export" : "Export journal…"
                        primary: root.restorePath === "" || root.pendingAction === "export"
                        enabled: !root.saving && !root.choosingFile && (!root.requestId || root.pendingAction === "export")
                        onClicked: root.exportFile()
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        visible: root.exportPath !== ""
                        text: "Selected: " + root.filename(root.exportPath)
                        maximumLineCount: 2
                        elide: Text.ElideMiddle
                    }
                    DButton {
                        theme: root.theme
                        quiet: true
                        visible: root.exportPath !== "" && !root.requestId
                        enabled: !root.saving && !root.choosingFile
                        text: "Choose another destination…"
                        onClicked: exportPicker.open()
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "Choose a new file. Existing files are never overwritten."
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(12)
                    DText { theme: root.theme; text: "Import a backup"; font.bold: true; Layout.fillWidth: true }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "Choose a Daymark or earlier Daylog JSON file. Import works only with a fresh, empty journal; existing records are never replaced."
                        color: root.theme.secondary
                    }
                    DButton {
                        theme: root.theme
                        objectName: "restoreChooseFile"
                        text: root.restorePath ? "Choose another backup…" : "Choose backup…"
                        enabled: !root.saving && !root.choosingFile && !root.requestId
                        onClicked: { root.dismissPending = false; restorePicker.open(); }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.restorePath !== ""
                        implicitHeight: selectedFileLabel.implicitHeight + root.theme.space(24)
                        color: root.theme.surface
                        radius: root.theme.radius
                        DText {
                            id: selectedFileLabel
                            theme: root.theme
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: root.theme.space(12)
                            text: root.filename(root.restorePath)
                            maximumLineCount: 2
                            elide: Text.ElideMiddle
                        }
                    }
                    RowLayout {
                        visible: root.restorePath !== ""
                        Layout.fillWidth: true
                        spacing: root.theme.space(12)
                        DButton {
                            id: importButton
                            theme: root.theme
                            objectName: "restoreConfirm"
                            text: root.pendingAction === "restore" ? "Retry import" : "Import journal"
                            primary: root.restorePath !== "" && root.pendingAction !== "export"
                            enabled: root.restorePath !== "" && !root.saving && !root.choosingFile && (!root.requestId || root.pendingAction === "restore")
                            onClicked: root.importFile()
                        }
                        DButton {
                            theme: root.theme
                            quiet: true
                            visible: root.restorePath !== ""
                            enabled: !root.saving && !root.choosingFile && !root.requestId
                            text: "Clear selection"
                            onClicked: root.restorePath = ""
                        }
                    }
                }
                DText {
                    theme: root.theme
                    objectName: "dataSafetyFeedback"
                    Layout.fillWidth: true
                    text: root.message
                    visible: text !== ""
                    color: root.failed ? root.theme.urgent : root.theme.secondary
                }
                ColumnLayout {
                    visible: root.failed && root.requestId !== ""
                    Layout.fillWidth: true
                    spacing: root.theme.space(12)
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "If a reply was lost, the action may already have completed. Retrying the same action is safe. Stopping its retry does not undo saved changes."
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                    }
                    DButton {
                        theme: root.theme
                        objectName: "safetyDiscardRequest"
                        text: "Stop retrying · keep selection"
                        enabled: !root.saving && !root.choosingFile
                        onClicked: {
                            root.requestId = "";
                            root.pendingPayload = "";
                            root.message = "Retry stopped. Your file selection is still here.";
                            root.failed = false;
                        }
                    }
                }
            }
        }
        ColumnLayout {
            visible: root.dismissPending
            Layout.fillWidth: true
            spacing: root.theme.space(12)
            DText {
                theme: root.theme
                Layout.fillWidth: true
                text: "Close and discard your file selection?" + (root.requestId ? " The action may already have completed. Closing stops its retry; it does not undo saved changes." : "")
            }
            Flow {
                Layout.fillWidth: true
                spacing: root.theme.space(12)
                DButton {
                    id: keepEditing
                    theme: root.theme
                    objectName: "dataSafetyKeepEditing"
                    text: "Keep open"
                    onClicked: root.dismissPending = false
                }
                DButton {
                    theme: root.theme
                    objectName: "dataSafetyDiscard"
                    text: "Discard selection and close"
                    enabled: !root.saving && !root.choosingFile
                    onClicked: root.discard()
                }
            }
        }
        DButton {
            theme: root.theme
            objectName: "dataSafetyClose"
            text: "Close"
            Layout.alignment: Qt.AlignRight
            visible: !root.dismissPending
            enabled: !root.saving && !root.choosingFile
            onClicked: root.requestDismiss()
        }
    }
}
