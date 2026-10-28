import QtQuick

// Workspace owns the single countdown; logging is an explicit journal handoff.
Item {
    id: root
    objectName: "countdownController"
    required property var store
    visible: false
    property string status: "idle"
    property int revision: 0
    property int durationSeconds: 0
    property real remainingExact: 0
    readonly property int remainingSeconds: Math.max(0, Math.ceil(remainingExact))
    property bool muted: false
    property string recovery: ""
    property string runId: ""
    property string activityId: ""
    property string taskId: ""
    property string activityTitle: ""
    property string taskTitle: ""
    property string targetError: ""
    property string selectedActivityId: ""
    property string selectedTaskId: ""
    property bool logPending: false
    property bool logSaved: false
    property var logPayload: null
    property bool loaded: false
    property bool busy: false
    property string error: ""
    property bool suspended: false
    property string soundError: ""
    readonly property string soundUnavailable: soundLoader.status === Loader.Error
        ? "Completion sound unavailable; the timer still works."
        : soundError || (soundLoader.item ? soundLoader.item.error : "")
    property string observer: "countdown-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
    property var retryRequest: null
    property real pollElapsed: 0
    property real projectionStamp: Date.now()
    property bool reconcileNeeded: false

    function dispatch(op, args, requestId, callback) {
        if (busy || suspended) return false;
        busy = true;
        error = "";
        const payload = Object.assign({observer: observer}, args);
        const id = requestId || store.newRequestId();
        store.request(op, payload, function(ok, result, failure) {
            const receivedAt = Date.now();
            const responseGap = receivedAt - projectionStamp;
            const delayed = responseGap < 0 || responseGap > 2000;
            if (delayed) reconcileNeeded = true;
            projectionStamp = receivedAt;
            if (ok) {
                status = result.status;
                revision = result.revision;
                durationSeconds = result.durationSeconds;
                remainingExact = result.remainingExact;
                muted = result.muted;
                recovery = result.recovery;
                runId = result.runId || "";
                activityId = result.activityId || "";
                taskId = result.taskId || "";
                activityTitle = result.activityTitle || "";
                taskTitle = result.taskTitle || "";
                targetError = result.targetError || "";
                logPending = !!result.logPending;
                logSaved = !!result.logSaved;
                logPayload = result.logPayload || null;
                if (status !== "idle") {
                    selectedActivityId = activityId;
                    selectedTaskId = taskId;
                }
                loaded = true;
                retryRequest = null;
                pollElapsed = 0;
                if (result.sound && !muted && !delayed && !reconcileNeeded) {
                    if (soundLoader.item && soundLoader.item.ready) soundLoader.item.play();
                    else soundError = "Completion sound unavailable; the timer finished silently.";
                }
            } else {
                error = failure.message || "Countdown state could not be saved.";
                retryRequest = failure.code === "conflict"
                    ? {op: "countdown_status", args: {observer: observer, attach: true}, id: store.newRequestId()}
                    : {op: op, args: payload, id: id};
            }
            busy = false;
            if (callback) callback(ok, result, failure);
            if (!ok && op === "countdown_log") Qt.callLater(refresh);
            if (ok && reconcileNeeded) {
                reconcileNeeded = false;
                Qt.callLater(refresh);
            }
        }, id);
        return true;
    }
    function refresh() { dispatch("countdown_status", {attach: !loaded}); }
    function retry() {
        if (retryRequest) dispatch(retryRequest.op, retryRequest.args, retryRequest.id);
        else refresh();
    }
    function change(op, args) {
        if (!loaded || busy || error) return;
        dispatch(op, Object.assign({expectedRevision: revision}, args || {}));
    }
    function selectTarget(activity, task) {
        if (!loaded || busy || suspended || status !== "idle" || logPending) return false;
        selectedActivityId = activity || "";
        selectedTaskId = task || "";
        return true;
    }
    function start(seconds) {
        change("countdown_start", {seconds: seconds, activityId: selectedActivityId, taskId: selectedTaskId});
    }
    function pause() { change("countdown_pause"); }
    function resume() { change("countdown_resume"); }
    function reset() { if (!logPending) change("countdown_reset"); }
    function saveEntry(args, callback) {
        if (!loaded || busy || suspended) {
            callback(false, null, {code: "busy", message: qsTr("Wait for the countdown operation to finish, then retry.")});
            return false;
        }
        const payload = {activityId: args.activityId, taskIds: (args.taskIds || []).slice(),
            date: args.date, note: args.note || "", done: !!args.done};
        if (logPending) {
            // Compare fields rather than property insertion order from Python JSON.
            const same = args.runId === runId && logPayload
                && payload.activityId === logPayload.activityId && payload.date === logPayload.date
                && payload.note === logPayload.note && payload.done === logPayload.done
                && JSON.stringify(payload.taskIds) === JSON.stringify(logPayload.taskIds);
            if (!same) {
                callback(false, null, {code: "conflict", message: qsTr("Retry the unchanged pending countdown entry before making another change.")});
                return false;
            }
        }
        // An acknowledgement may be lost. Freeze the submitted values until a
        // backend status proves no durable intent exists, or confirms its receipt.
        if (args.runId === runId) { logPending = true; logPayload = payload; }
        return dispatch("countdown_log", Object.assign({runId: args.runId}, payload), "",
            (ok, result, failure) => callback(ok, ok ? result.entry : null, failure));
    }
    function toggleMute() { change("countdown_mute", {muted: !muted}); }

    function project(now) {
        const delta = (now - projectionStamp) / 1000;
        projectionStamp = now;
        if (delta < 0 || delta > 2) {
            // Wall time is only a rendering projection. Sleep/clock changes
            // demand a fresh boottime sample, never a guessed deadline.
            reconcileNeeded = true;
        } else {
            if (status === "running") remainingExact = Math.max(0, remainingExact - delta);
            pollElapsed += delta;
        }
        if (!busy && (reconcileNeeded || (status === "running" && remainingExact === 0)
                || pollElapsed >= (status === "running" ? 10 : 30))) {
            reconcileNeeded = false;
            refresh();
        }
    }

    Loader {
        id: soundLoader
        asynchronous: true
        source: "CountdownSound.qml"
    }
    // Tick locally; SQLite's CLOCK_BOOTTIME is authoritative and corrects
    // sleep/render delays. Wall-clock changes never alter the stored deadline.
    Timer {
        interval: 250
        repeat: true
        running: root.loaded && !root.error && !root.suspended
        onTriggered: root.project(Date.now())
    }
    Component.onCompleted: Qt.callLater(refresh)
}
