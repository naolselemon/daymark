import QtQuick

// Workspace owns this once, not the visible Timer page. No journal sessions.
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
    property bool loaded: false
    property bool busy: false
    property string error: ""
    property string soundError: ""
    readonly property string soundUnavailable: soundLoader.status === Loader.Error
        ? "Completion sound unavailable; the timer still works."
        : soundError || (soundLoader.item ? soundLoader.item.error : "")
    property string observer: "countdown-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
    property var retryRequest: null
    property real pollElapsed: 0
    property real projectionStamp: Date.now()
    property bool reconcileNeeded: false

    function dispatch(op, args, requestId) {
        if (busy) return;
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
            if (ok && reconcileNeeded) {
                reconcileNeeded = false;
                Qt.callLater(refresh);
            }
        }, id);
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
    function start(seconds) { change("countdown_start", {seconds: seconds}); }
    function pause() { change("countdown_pause"); }
    function resume() { change("countdown_resume"); }
    function reset() { change("countdown_reset"); }
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
        running: root.loaded && !root.error
        onTriggered: root.project(Date.now())
    }
    Component.onCompleted: Qt.callLater(refresh)
}
