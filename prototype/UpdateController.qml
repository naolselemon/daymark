import QtQuick

// Network and installation requests never block the journal's storage queue.
QtObject {
    id: root
    required property var transport
    required property var preferences
    property bool canApply: false
    property string blockReason: ""
    property bool loaded: false
    property bool busy: false
    property string error: ""
    property var info: ({installedVersion: "", availableVersion: "", availableCommit: "",
        lastAttemptAt: 0, lastCheckedAt: 0, phase: "idle", supported: false, message: ""})
    property var pending: null
    property int sequence: 0
    property bool refreshingAfterFailure: false
    property bool installUncertain: false
    readonly property bool applying: installUncertain || info.phase === "installing"
        || (pending !== null && pending.op === "update_install")
    readonly property real checkInterval: 24 * 60 * 60 * 1000
    // A clock seam lets isolated tests exercise restart/sleep boundaries.
    property var now: () => Date.now()

    function validInfo(value) {
        return value && typeof value.installedVersion === "string"
            && typeof value.availableVersion === "string" && typeof value.availableCommit === "string"
            && (value.availableCommit === "" || /^[0-9a-f]{40}$/.test(value.availableCommit))
            && typeof value.lastAttemptAt === "number" && Number.isFinite(value.lastAttemptAt) && value.lastAttemptAt >= 0
            && typeof value.lastCheckedAt === "number" && Number.isFinite(value.lastCheckedAt) && value.lastCheckedAt >= 0
            && ["idle", "current", "ready", "installing", "updated"].indexOf(value.phase) >= 0
            && typeof value.supported === "boolean" && typeof value.message === "string";
    }
    function dispatch(op, args) {
        if (busy) return false;
        if (!transport) {
            error = "The update helper is unavailable.";
            return false;
        }
        const id = "update-" + Date.now().toString(36) + "-" + (++sequence).toString(36);
        pending = {protocol: 1, requestId: id, op: op, args: args || {}};
        busy = true;
        if (!refreshingAfterFailure) error = "";
        try {
            if (!transport.send(JSON.stringify(pending)))
                acceptReply("", "The update helper could not accept the request.");
        } catch (_) {
            acceptReply("", "The update helper is unavailable.");
        }
        return true;
    }
    function refresh() { return dispatch("update_status", {}); }
    function check() {
        if (applying || refreshingAfterFailure) return false;
        return dispatch("update_check", {});
    }
    function applyApproved(commit) {
        if (busy || applying || refreshingAfterFailure || !canApply || !info.supported || info.phase !== "ready"
                || commit !== info.availableCommit || !/^[0-9a-f]{40}$/.test(commit)) {
            error = blockReason || "This update is no longer ready. Check again before applying it.";
            return false;
        }
        return dispatch("update_install", {commit: commit, restartApproved: true});
    }
    function checkIfDue() {
        if (!loaded || busy || applying || refreshingAfterFailure || !preferences.loaded || !preferences.automaticUpdates || !info.supported) return;
        const time = now();
        if (info.lastAttemptAt === 0 || time - info.lastAttemptAt >= checkInterval || time < info.lastAttemptAt)
            check();
    }
    function acceptReply(text, transportError) {
        if (!pending) return;
        const job = pending;
        let response;
        try {
            if (transportError) throw new Error(transportError);
            response = JSON.parse(text);
            if (response.protocol !== 1 || response.requestId !== job.requestId || typeof response.ok !== "boolean"
                    || (response.ok && !validInfo(response.result))
                    || (!response.ok && (!response.error || typeof response.error.message !== "string")))
                throw new Error("The update helper returned an invalid response.");
        } catch (failure) {
            response = {ok: false, error: {message: failure.message}};
            if (job.op === "update_install") installUncertain = true;
        }
        if (response.ok) {
            info = response.result;
            loaded = true;
            if (job.op === "update_status") installUncertain = false;
            if (!refreshingAfterFailure) error = "";
        } else {
            error = response.error.message;
        }
        pending = null;
        busy = false;
        if (!response.ok && job.op !== "update_status") {
            // Read the saved attempt/result without retrying a network request or
            // repeating an installation whose outcome might be unknown.
            refreshingAfterFailure = true;
            Qt.callLater(refresh);
        } else {
            const wasRecovering = refreshingAfterFailure;
            refreshingAfterFailure = false;
            if (response.ok && !wasRecovering && job.op === "update_status")
                Qt.callLater(checkIfDue);
        }
    }
    property Connections transportSignals: Connections {
        target: root.transport
        function onFinished(response, transportError) { root.acceptReply(response, transportError); }
    }
    property Connections preferenceSignals: Connections {
        target: root.preferences
        function onLoadedChanged() { Qt.callLater(root.checkIfDue); }
        function onAutomaticUpdatesChanged() { Qt.callLater(root.checkIfDue); }
    }
    property Timer dailyCheck: Timer {
        interval: 60000
        repeat: true
        running: root.loaded && root.preferences.loaded && root.preferences.automaticUpdates
        onTriggered: root.checkIfDue()
    }
    property Timer installationStatus: Timer {
        interval: 2000
        repeat: true
        running: root.applying && !root.busy
        onTriggered: root.refresh()
    }
    Component.onCompleted: Qt.callLater(refresh)
}
