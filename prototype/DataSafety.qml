pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Dialogs

Popup {
    id: root
    required property var theme
    required property var store
    required property var workspace
    property bool saving: false
    property string message: ""
    property bool failed: false
    property string requestId: ""
    property string pendingPayload: ""
    property string activitiesExportPath: ""
    property string diaryExportPath: ""
    property string chooserScope: "activities"
    property string restorePath: ""
    property bool dismissPending: false
    property var importResult: null
    property bool conflictsExpanded: false
    property int conflictPage: 0
    readonly property var importConflicts: importResult ? importResult.conflicts : []
    readonly property var recordNames: ({
        categories: "Category", projects: "Project", activities: "Activity", sessions: "Log",
        day_notes: "Diary page", activity_events: "History event", timer_sessions: "Timer history",
        session_intervals: "Time interval", trash: "Deleted record"
    })
    readonly property string pendingAction: pendingPayload ? JSON.parse(pendingPayload)[0] : ""
    readonly property string pendingScope: pendingAction === "export" ? JSON.parse(pendingPayload)[1][2] : ""
    readonly property bool dirty: activitiesExportPath !== "" || diaryExportPath !== "" || restorePath !== "" || requestId !== ""
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

    function clearImportResult() {
        importResult = null;
        conflictsExpanded = false;
        conflictPage = 0;
    }
    function importSummary(result) {
        const added = result.counts;
        const core = added.activities + added.sessions + added.day_notes;
        const supporting = Object.values(added).reduce((sum, count) => sum + count, 0) - core;
        const duplicates = Object.values(result.duplicates).reduce((sum, count) => sum + count, 0);
        let summary = "Added " + added.activities + (added.activities === 1 ? " activity, " : " activities, ")
            + added.sessions + (added.sessions === 1 ? " log and " : " logs and ")
            + added.day_notes + (added.day_notes === 1 ? " diary page." : " diary pages.");
        if (supporting) summary += " " + supporting + (supporting === 1 ? " supporting record added." : " supporting records added.");
        summary += "\n" + duplicates + (duplicates === 1 ? " matching record skipped." : " matching records skipped.");
        if (result.conflicts.length)
            summary += " " + result.conflicts.length + (result.conflicts.length === 1 ? " conflict skipped" : " conflicts skipped")
                + "; your existing versions were kept.";
        return summary;
    }
    function begin() {
        if (opened) return;
        if (!dirty) { message = ""; failed = false; clearImportResult(); }
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
        activitiesExportPath = "";
        diaryExportPath = "";
        restorePath = "";
        requestId = "";
        pendingPayload = "";
        message = "";
        failed = false;
        dismissPending = false;
        clearImportResult();
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
        clearImportResult();
        saving = true;
        failed = false;
        dismissPending = false;
        message = action === "export" ? "Exporting " + (args[2] === "diary" ? "diary pages…" : "activities…") : "Importing your journal…";
        operation((ok, result, error) => {
            saving = false;
            failed = !ok;
            if (!ok) {
                message = (error && error.message ? error.message : "Could not finish.")
                    + (action === "export" ? " Your destination is kept. Retrying never overwrites an existing file."
                                          : " Your file selection is kept. Retry the same action to safely recover its result.");
                return;
            }
            requestId = "";
            pendingPayload = "";
            if (action === "export") {
                message = "JSON archive saved to " + (result && result.path ? result.path : args[1]);
                if (args[2] === "diary") diaryExportPath = "";
                else activitiesExportPath = "";
            } else {
                importResult = result;
                message = importSummary(result);
                restorePath = "";
            }
        }, requestId);
    }
    function localPath(fileUrl) {
        // Decode the URL pathname once: encoded #, % and Unicode belong to the filename.
        const match = /^file:\/\/(?:localhost)?(\/[^?#]*)$/i.exec(fileUrl.toString());
        if (!match) {
            failed = true;
            message = "Choose a location on this computer.";
            return "";
        }
        try { return decodeURIComponent(match[1]); }
        catch (error) {
            failed = true;
            message = "This location could not be read. Choose it again.";
            return "";
        }
    }
    function filename(path) { return path.slice(path.lastIndexOf("/") + 1); }
    function selectedExportPath(scope) {
        return scope === "diary" ? diaryExportPath : activitiesExportPath;
    }
    function chooseExportFolder(scope) {
        if (saving || choosingFile || requestId || workspace.diaryAuthenticating) return;
        chooserScope = scope;
        dismissPending = false;
        clearImportResult();
        exportPicker.open();
    }
    function exportFile(scope) {
        if (scope !== "activities" && scope !== "diary") return;
        if (saving || choosingFile || workspace.diaryAuthenticating
                || (requestId && (pendingAction !== "export" || pendingScope !== scope))) return;
        dismissPending = false;
        const path = selectedExportPath(scope);
        if (!path) { chooseExportFolder(scope); return; }
        const dispatch = () => {
            if (root.opened && root.selectedExportPath(scope) === path)
                root.run("export", ["json", path, scope],
                         (cb, id) => root.store.exportRecords("json", path, scope, cb, id));
        };
        if (scope === "diary")
            workspace.authorizeDiary(dispatch, "Export diary pages · plaintext JSON", true);
        else dispatch();
    }
    function importFile() {
        if (!restorePath || saving || choosingFile || workspace.diaryAuthenticating
                || (requestId && pendingAction !== "restore")) return;
        const path = restorePath;
        workspace.authorizeDiary(() => {
            if (root.opened && root.restorePath === path)
                root.run("restore", [path], (cb, id) => root.store.restoreRecords(path, cb, id));
        }, "Authorize journal import", true);
    }

    FolderDialog {
        id: exportPicker
        objectName: "exportFolderDialog"
        title: root.chooserScope === "diary" ? "Choose a folder for your diary backup" : "Choose a folder for your activity backup"
        acceptLabel: "Export here"
        onAccepted: {
            const folder = root.localPath(selectedFolder);
            if (!folder) return;
            const scope = root.chooserScope;
            const name = "daymark-" + scope + "-" + Qt.formatDateTime(new Date(), "yyyy-MM-dd-HHmmss-zzz") + ".json";
            const path = folder + (folder.endsWith("/") ? "" : "/") + name;
            if (scope === "diary") root.diaryExportPath = path;
            else root.activitiesExportPath = path;
            // The native window can still report visible while accepting its selection.
            Qt.callLater(() => root.exportFile(scope));
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
            root.clearImportResult();
            root.message = "";
            root.failed = false;
            importButton.forceActiveFocus();
        }
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.opened && !root.choosingFile && !root.workspace.diaryAuthenticating
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
                    DText { theme: root.theme; text: "Export activities"; font.bold: true; Layout.fillWidth: true }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "Plans, logs and activity recovery records only. Diary pages and diary trash are never included. JSON is plaintext, not encrypted."
                        color: root.theme.secondary
                    }
                    DButton {
                        theme: root.theme
                        objectName: "exportActivities"
                        text: root.pendingScope === "activities" ? "Retry activities export" : "Export activities…"
                        iconName: "export"
                        primary: root.restorePath === "" && root.pendingScope !== "diary"
                        enabled: !root.saving && !root.choosingFile && !root.workspace.diaryAuthenticating
                                 && (!root.requestId || root.pendingScope === "activities")
                        onClicked: root.exportFile("activities")
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        visible: root.activitiesExportPath !== ""
                        text: "Selected: " + root.filename(root.activitiesExportPath)
                        maximumLineCount: 2
                        elide: Text.ElideMiddle
                    }
                    DButton {
                        theme: root.theme
                        quiet: true
                        visible: root.activitiesExportPath !== "" && !root.requestId
                        enabled: !root.saving && !root.choosingFile && !root.workspace.diaryAuthenticating
                        text: "Choose another activities destination…"
                        iconName: "pages"
                        onClicked: root.chooseExportFolder("activities")
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "A dated backup file is created in the folder you choose. Existing files are never overwritten."
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(12)
                    DText { theme: root.theme; text: "Export diary"; font.bold: true; Layout.fillWidth: true }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        text: "Diary pages and their recovery records only, without activities. Your system password is required every time, including retries. The saved JSON is plaintext, not encrypted."
                        color: root.theme.secondary
                    }
                    DButton {
                        theme: root.theme
                        objectName: "exportDiary"
                        text: root.pendingScope === "diary" ? "Retry diary export" : "Export diary…"
                        iconName: "export"
                        enabled: !root.saving && !root.choosingFile && !root.workspace.diaryAuthenticating
                                 && (!root.requestId || root.pendingScope === "diary")
                        onClicked: root.exportFile("diary")
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        visible: root.diaryExportPath !== ""
                        text: "Selected: " + root.filename(root.diaryExportPath)
                        maximumLineCount: 2
                        elide: Text.ElideMiddle
                    }
                    DButton {
                        theme: root.theme
                        quiet: true
                        visible: root.diaryExportPath !== "" && !root.requestId
                        enabled: !root.saving && !root.choosingFile && !root.workspace.diaryAuthenticating
                        text: "Choose another diary destination…"
                        iconName: "pages"
                        onClicked: root.chooseExportFolder("diary")
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
                        text: "Add an activities, diary or older combined JSON backup. Your password is required because a backup may contain diary pages. Matching records are skipped; existing versions are kept and conflicts reported."
                        color: root.theme.secondary
                    }
                    DButton {
                        theme: root.theme
                        objectName: "restoreChooseFile"
                        text: root.restorePath ? "Choose another backup…" : "Choose backup…"
                        iconName: "import"
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
                            text: root.pendingAction === "restore" ? "Retry import" : "Add from backup"
                            iconName: "import"
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
                            iconName: "close"
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
                    Layout.fillWidth: true
                    visible: root.importConflicts.length > 0
                    spacing: root.theme.space(12)
                    DButton {
                        theme: root.theme; quiet: true; objectName: "importConflictsToggle"
                        text: root.conflictsExpanded && root.workspace.diaryUnlocked
                            ? "Hide skipped records" : "Show skipped records · " + root.importConflicts.length
                        iconName: root.conflictsExpanded && root.workspace.diaryUnlocked ? "collapse" : "expand"
                        onClicked: {
                            if (root.conflictsExpanded && root.workspace.diaryUnlocked)
                                root.conflictsExpanded = false;
                            else root.workspace.authorizeDiary(() => {
                                if (root.opened) root.conflictsExpanded = true;
                            }, "View skipped import records");
                        }
                    }
                    ColumnLayout {
                        id: conflictDetails
                        Layout.fillWidth: true
                        visible: root.conflictsExpanded && root.workspace.diaryUnlocked
                        spacing: root.theme.space(16)
                        DText {
                            theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                            text: "Nothing here replaced your current records. The skipped versions remain in the backup file."
                        }
                        Repeater {
                            model: conflictDetails.visible ? root.importConflicts.slice(root.conflictPage * 20, (root.conflictPage + 1) * 20) : []
                            ColumnLayout {
                                id: conflictRow
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: root.theme.space(4)
                                DText {
                                    theme: root.theme; Layout.fillWidth: true; font.bold: true
                                    text: root.recordNames[conflictRow.modelData.table] + " · " + conflictRow.modelData.label
                                }
                                DText {
                                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                                    text: conflictRow.modelData.reason
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.importConflicts.length > 20
                            DButton {
                                theme: root.theme; text: "Previous"; objectName: "importConflictsPrevious"
                                iconName: "back"
                                enabled: root.conflictPage > 0
                                onClicked: root.conflictPage--
                            }
                            DText {
                                theme: root.theme; Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: "Page " + (root.conflictPage + 1) + " of " + Math.ceil(root.importConflicts.length / 20)
                            }
                            DButton {
                                theme: root.theme; text: "Next"; objectName: "importConflictsNext"
                                iconName: "next"
                                enabled: (root.conflictPage + 1) * 20 < root.importConflicts.length
                                onClicked: root.conflictPage++
                            }
                        }
                    }
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
            iconName: "close"
            Layout.alignment: Qt.AlignRight
            visible: !root.dismissPending
            enabled: !root.saving && !root.choosingFile
            onClicked: root.requestDismiss()
        }
    }
}
