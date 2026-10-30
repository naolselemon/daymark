import QtQuick

// A dedicated transport keeps feed requests out of the journal's storage queue.
QtObject {
    id: root
    required property var transport
    objectName: "calendarController"
    property string viewDate: Qt.formatDate(new Date(), "yyyy-MM-dd")
    property bool loaded: false
    property bool busy: false
    property bool suspended: false
    property string error: ""
    property var info: ({configured: false, name: "", enabled: false, lastCheckedAt: 0,
        lastSuccessAt: 0, error: "", windowStart: "", windowEnd: "", events: [],
        reminderDate: "", reminderEvents: []})
    readonly property bool configured: info.configured
    readonly property var events: info.events
    readonly property string reminderDate: info.reminderDate
    readonly property var reminderEvents: info.reminderEvents
    readonly property var agendaEvents: reminderEvents
    readonly property bool stale: configured && (error !== "" || info.error !== ""
        || !info.lastSuccessAt || clock - info.lastSuccessAt * 1000 >= refreshInterval)
    readonly property string statusText: !loaded ? qsTr("Not loaded") : !configured ? qsTr("Not connected")
        : !info.enabled ? qsTr("Paused") : stale ? qsTr("Saved calendar · needs refresh") : qsTr("Up to date")
    readonly property string windowLabel: info.windowStart && info.windowEnd
        ? qsTr("%1 – %2").arg(formatDay(info.windowStart)).arg(formatDay(info.windowEnd)) : ""
    readonly property real refreshInterval: 60 * 60 * 1000
    property var now: () => Date.now()
    property real clock: now()
    property real lastAttempt: 0
    property string projectionKey: localDayZone(now())
    property int sequence: 0
    property var pending: null
    property bool projectionPending: false
    property var queuedClaimFloor: null
    property bool cancelRequested: false
    signal operationFinished(string operation, bool success)
    signal reminderClaimsFinished(var claims, real notBefore)

    function formatDay(day) { return Qt.formatDate(new Date(day + "T12:00:00"), "d MMM yyyy"); }
    function localDayZone(stamp) {
        const date = new Date(stamp);
        return Qt.formatDate(date, "yyyy-MM-dd") + "/" + date.getTimezoneOffset();
    }
    function validDate(value) {
        return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)
            && Qt.formatDate(new Date(value + "T12:00:00"), "yyyy-MM-dd") === value;
    }
    function validEvent(event) {
        return event && typeof event.id === "string" && typeof event.title === "string"
            && validDate(event.startDate) && validDate(event.endDate) && event.endDate >= event.startDate
            && typeof event.allDay === "boolean" && typeof event.startTime === "string"
            && typeof event.endTime === "string"
            && (event.allDay ? event.startEpoch === null
                : Number.isFinite(event.startEpoch) && validDate(event.endTimeDate)
                    && /^\d{2}:\d{2}$/.test(event.startTime) && /^\d{2}:\d{2}$/.test(event.endTime));
    }
    function validInfo(value) {
        return value && typeof value.configured === "boolean" && typeof value.enabled === "boolean"
            && typeof value.name === "string" && typeof value.error === "string"
            && Number.isFinite(value.lastCheckedAt) && value.lastCheckedAt >= 0
            && Number.isFinite(value.lastSuccessAt) && value.lastSuccessAt >= 0
            && (value.windowStart === "" || validDate(value.windowStart))
            && (value.windowEnd === "" || validDate(value.windowEnd))
            && Array.isArray(value.events) && value.events.every(validEvent)
            && validDate(value.reminderDate) && Array.isArray(value.reminderEvents)
            && value.reminderEvents.every(validEvent);
    }
    function validClaims(value) {
        return value && Array.isArray(value.claims) && value.claims.every(claim => claim
            && typeof claim.id === "string" && claim.id !== ""
            && typeof claim.title === "string" && Number.isFinite(claim.startEpoch));
    }
    function failureMessage(op, code) {
        if (code === "dependencies") return qsTr("Calendar support needs icalendar and recurring-ical-events in Daymark's isolated Python environment. Follow the calendar setup instructions, then try again.");
        if (code === "calendar") return qsTr("The feed could not be read as an iCalendar calendar. Check the Google Calendar iCal address. Saved events and your draft are unchanged.");
        if (code === "limit") return qsTr("This calendar exceeds the supported feed size or occurrence limit. Use a smaller calendar. Saved events and your draft are unchanged.");
        if (code === "read_only") return qsTr("Calendar settings cannot be changed in this read-only profile.");
        if (code === "conflict") return qsTr("Another calendar request changed the saved settings. Refresh the saved state and try again.");
        if (code === "storage") return qsTr("Calendar settings could not be saved. Check access to Daymark's data directory and try again.");
        if (op === "calendar_configure") return qsTr("Could not confirm the connection. Check the private Google Calendar iCal address and your connection. Your draft has been kept.");
        if (op === "calendar_disconnect") return qsTr("Could not disconnect the calendar. Try again.");
        if (op === "calendar_status") return qsTr("Could not load the saved calendar. Try again.");
        if (op === "calendar_claim") return qsTr("The calendar reminder could not be confirmed. It will not be replayed.");
        return qsTr("Could not refresh the calendar. Showing the last saved events; check your connection and try again.");
    }
    function dispatch(op, args, retainedError = "") {
        if (busy || suspended) return false;
        if (!transport) { error = qsTr("The calendar helper is unavailable."); return false; }
        const requestId = "calendar-" + now().toString(36) + "-" + (++sequence).toString(36);
        // Never retain the URL in request state or expose transport diagnostics.
        pending = {requestId: requestId, op: op, date: args.date || "", retainedError: retainedError,
            notBefore: op === "calendar_claim" ? args.notBefore : 0};
        busy = true;
        error = "";
        if (op === "calendar_refresh" || op === "calendar_configure") lastAttempt = now();
        if (op !== "calendar_claim") projectionKey = localDayZone(now());
        try {
            if (!transport.send(JSON.stringify({protocol: 1, requestId: requestId, op: op, args: args})))
                acceptReply("", true);
        } catch (_) { acceptReply("", true); }
        return true;
    }
    function loadStatus(retainedError = "") {
        if (busy) { projectionPending = true; return false; }
        projectionPending = false;
        return dispatch("calendar_status", {date: viewDate}, retainedError);
    }
    function refresh() {
        if (!configured || !info.enabled) return false;
        return dispatch("calendar_refresh", {date: viewDate});
    }
    function claimReminders(notBefore) {
        const age = now() / 1000 - notBefore;
        if (!loaded || !configured || !info.enabled || suspended
                || !Number.isFinite(notBefore) || age < 0 || age > 15) return false;
        if (busy) {
            queuedClaimFloor = notBefore;
            return true;
        }
        return dispatch("calendar_claim", {notBefore: notBefore});
    }
    function configure(url, name) {
        if (busy) return false;
        const address = url.trim();
        if (!/^https:\/\/calendar\.google\.com\/calendar\/ical\/[^?#\s]+\.ics$/.test(address)) {
            error = qsTr("Use the HTTPS private iCal address from Google Calendar, without a query or fragment.");
            return false;
        }
        return dispatch("calendar_configure", {url: address, name: name.trim(), enabled: true, date: viewDate});
    }
    function disconnectFeed() { return dispatch("calendar_disconnect", {}); }
    function cancel() {
        if (!pending || cancelRequested || !transport) return;
        cancelRequested = true;
        error = qsTr("Canceling request…");
        // Wait for the child to be reaped before using this transport again.
        try { transport.cancel(); } catch (_) {
            cancelRequested = false;
            error = qsTr("Could not cancel. Wait for the calendar request to finish.");
        }
    }
    function checkIfDue() {
        clock = now();
        if (!loaded || !configured || !info.enabled || busy || suspended) return;
        const attempt = Math.max(lastAttempt, info.lastCheckedAt * 1000);
        if (!attempt || clock < attempt || clock - attempt >= refreshInterval) refresh();
        else if (projectionKey !== localDayZone(clock)) loadStatus();
    }
    function acceptReply(text, transportError) {
        if (!pending) return;
        const job = pending;
        if (cancelRequested) {
            cancelRequested = false;
            pending = null;
            busy = false;
            error = qsTr("Request canceled. Checking the saved calendar state.");
            operationFinished(job.op, false);
            const queuedFloor = queuedClaimFloor;
            queuedClaimFloor = null;
            if (job.op === "calendar_claim") reminderClaimsFinished([], job.notBefore);
            if (queuedFloor !== null) reminderClaimsFinished([], queuedFloor);
            // Cancellation may race an atomic backend save; never assume rollback.
            Qt.callLater(loadStatus);
            return;
        }
        let response = null;
        let valid = false;
        try {
            if (!transportError) {
                response = JSON.parse(text);
                // Late responses cannot acknowledge a newer request.
                if (response && response.requestId && response.requestId !== job.requestId) return;
                valid = response && response.protocol === 1 && response.requestId === job.requestId
                    && typeof response.ok === "boolean" && (!response.ok
                        || (job.op === "calendar_claim" ? validClaims(response.result) : validInfo(response.result)));
            }
        } catch (_) { }
        const success = valid && response.ok;
        const firstLoad = !loaded;
        if (success && job.op !== "calendar_claim") {
            const result = response.result;
            info = {configured: result.configured, name: result.name, enabled: result.enabled,
                lastCheckedAt: result.lastCheckedAt, lastSuccessAt: result.lastSuccessAt,
                error: result.error,
                windowStart: result.windowStart, windowEnd: result.windowEnd, events: result.events,
                reminderDate: result.reminderDate, reminderEvents: result.reminderEvents};
            loaded = true;
            error = job.retainedError || info.error;
        } else if (!success) error = failureMessage(job.op, valid && response.error ? response.error.code : "");
        pending = null;
        busy = false;
        clock = now();
        if (queuedClaimFloor !== null) {
            const floor = queuedClaimFloor;
            queuedClaimFloor = null;
            Qt.callLater(() => { if (!claimReminders(floor)) reminderClaimsFinished([], floor); });
        }
        operationFinished(job.op, success);
        if (job.op === "calendar_claim") reminderClaimsFinished(success ? response.result.claims : [], job.notBefore);
        if (!success && job.op !== "calendar_status" && job.op !== "calendar_claim") {
            // A failed acknowledgement may follow a committed write or a competing request.
            // Read the durable state; never replay the mutation or discard its error/draft.
            const retainedError = error;
            Qt.callLater(() => loadStatus(retainedError));
        } else if (projectionPending || (job.date && job.date !== viewDate)) Qt.callLater(loadStatus);
        else if (success && firstLoad) Qt.callLater(checkIfDue);
    }
    onViewDateChanged: { if (loaded || busy) loadStatus(); }
    onSuspendedChanged: { if (!suspended) Qt.callLater(loadStatus); }
    property Connections transportSignals: Connections {
        target: root.transport
        function onFinished(response, transportError) { root.acceptReply(response, transportError); }
    }
    property Timer refreshClock: Timer {
        objectName: "calendarRefreshTimer"
        interval: 1000
        repeat: true
        running: root.loaded && root.configured && root.info.enabled && !root.suspended
        onTriggered: root.checkIfDue()
    }
    Component.onCompleted: Qt.callLater(loadStatus)
    Component.onDestruction: {
        pending = null;
        if (busy && transport) { try { transport.cancel(); } catch (_) { } }
    }
}
