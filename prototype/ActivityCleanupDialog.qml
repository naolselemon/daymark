pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    required property var store
    required property var workspace
    property string operation: ""
    property var requestArgs: ({})
    property string error: ""
    property bool saving: false
    property bool authenticating: false
    property int authorizationGeneration: 0
    readonly property bool wiping: operation === "wipe_activity_data"
    readonly property string confirmationPhrase: wiping ? "WIPE ALL ACTIVITY DATA" : "RESET TODAY"
    readonly property string blockReason: workspace.cleanupBlockReason
    signal completed(string operation, var result)
    objectName: "activityCleanupDialog"
    modal: true; focus: true; z: 10
    anchors.centerIn: parent
    width: Math.max(0, Math.min(parent.width - theme.space(24), theme.space(540)))
    height: Math.max(0, Math.min(parent.height - theme.space(24), implicitHeight))
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(24)
    closePolicy: saving || authenticating ? Popup.NoAutoClose : Popup.CloseOnEscape
    background: Rectangle { color: root.theme.surface; radius: root.theme.radius; border.color: root.theme.urgent }

    function begin(kind) {
        if (saving || authenticating || opened || (kind !== "reset_today_entries" && kind !== "wipe_activity_data")) return;
        const retry = store.cleanupRetry;
        operation = retry ? retry.op : kind;
        requestArgs = retry ? Object.assign({}, retry.args) : operation === "reset_today_entries"
            ? {date: Qt.formatDate(new Date(), "yyyy-MM-dd"), expectedRevision: store.records.revision}
            : {expectedRevision: store.records.revision};
        error = retry ? qsTr("The previous result is unknown. Confirm again to check the same deletion receipt; this will not delete newer data.") : "";
        confirmation.clear();
        open();
        cancelButton.forceActiveFocus(Qt.PopupFocusReason);
    }
    function authenticationCancelled() {
        if (!authenticating) return;
        authorizationGeneration += 1;
        authenticating = false;
        confirmation.clear();
    }
    function revokeAuthorization() {
        authorizationGeneration += 1;
        if (authenticating) {
            authenticating = false;
            workspace.cancelDiaryAuthentication();
        }
        confirmation.clear();
    }
    function requestDismiss() {
        if (saving) return false;
        revokeAuthorization();
        close();
        return true;
    }
    function staleReviewMessage() {
        if (store.cleanupRetry) return "";
        if (!wiping && requestArgs.date !== Qt.formatDate(new Date(), "yyyy-MM-dd"))
            return qsTr("The local day changed. Cancel and review Reset today again.");
        if (requestArgs.expectedRevision !== store.records.revision)
            return qsTr("The journal changed. Cancel and review this action again.");
        return "";
    }
    function approve() {
        if (!opened || saving || authenticating || confirmation.text !== confirmationPhrase) return;
        if (blockReason) { error = blockReason; return; }
        const stale = staleReviewMessage();
        if (stale) { error = stale; return; }
        const generation = ++authorizationGeneration;
        authenticating = true;
        workspace.authorizeDiary(() => {
            if (generation !== authorizationGeneration || !opened || !authenticating) return;
            authenticating = false;
            confirmation.clear();
            if (blockReason) { error = blockReason; return; }
            const changedReview = staleReviewMessage();
            if (changedReview) { error = changedReview; return; }
            saving = true;
            error = "";
            store.cleanupActivityData(operation, requestArgs, (ok, result, failure) => {
                saving = false;
                if (!ok) {
                    error = failure.code === "conflict"
                        ? (failure.message || qsTr("The journal changed.")) + " " + qsTr("Cancel and review this action again.")
                        : failure.message || qsTr("Activity data could not be deleted. Review and confirm again to retry.");
                    return;
                }
                completed(operation, result);
                close();
            });
        }, wiping ? qsTr("Authorize wiping all activity data") : qsTr("Authorize resetting today's entries"), true);
    }
    onClosed: revokeAuthorization()

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(16)
        DText {
            theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.title; font.bold: true
            text: root.wiping ? qsTr("Wipe all activity data?") : qsTr("Reset today's activity entries?")
        }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 0
            Layout.preferredHeight: fields.implicitHeight
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: fields
                width: parent.width
                spacing: root.theme.space(12)
                DText {
                    theme: root.theme; Layout.fillWidth: true
                    text: root.wiping
                        ? qsTr("Permanently delete all activities, tasks, plans, activity entries, activity trash and category/project labels. Keep Diary entries and diary trash, settings and Calendar data.")
                        : qsTr("Permanently delete activity entries dated %1, including that date's entry trash. Keep activities, tasks and their completion states, plans, Diary and Calendar data. Other dates stay unchanged.").arg(root.requestArgs.date || "")
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.urgent
                    text: qsTr("This cannot be undone. Plaintext backups and exports are not erased; internal retry receipts are retained. This is not secure erasure. Export anything you want to keep before continuing.")
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                    text: qsTr("A fresh system-password check is required after this confirmation. It does not unlock your Diary.")
                }
                DText { theme: root.theme; Layout.fillWidth: true; text: qsTr("Type %1 to confirm.").arg(root.confirmationPhrase) }
                DField {
                    id: confirmation
                    theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
                    objectName: "activityCleanupConfirmation"
                    Accessible.name: qsTr("Deletion confirmation")
                    enabled: !root.saving && !root.authenticating
                    selectByMouse: true
                    onAccepted: root.approve()
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.urgent
                    objectName: "activityCleanupError"
                    text: root.error || (!root.saving && !root.authenticating ? root.blockReason : "")
                    visible: text !== ""
                    Accessible.role: Accessible.AlertMessage
                }
            }
        }
        Flow {
            Layout.fillWidth: true; spacing: root.theme.space(8)
            DButton {
                id: cancelButton
                theme: root.theme; text: qsTr("Cancel"); objectName: "activityCleanupCancel"
                enabled: !root.saving && !root.authenticating
                onClicked: root.requestDismiss()
            }
            DButton {
                theme: root.theme; objectName: "activityCleanupApprove"
                text: root.saving ? qsTr("Deleting…") : qsTr("Verify password & delete")
                width: Math.min(implicitWidth, parent.width)
                enabled: !root.saving && !root.authenticating && !root.blockReason && confirmation.text === root.confirmationPhrase
                onClicked: root.approve()
            }
        }
    }
}
