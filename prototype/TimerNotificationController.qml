import QtQuick

// Only committed backend claims enter here; visual countdown ticks never do.
QtObject {
    id: root
    property var transport: null
    property bool checked: false
    property bool available: false
    property string error: ""
    property string calendarDeliveryError: ""
    readonly property string calendarError: !available ? error : calendarDeliveryError
    property int lastClaimRevision: -1
    property var calendarClaims: ({})
    property var pending: ({})
    property int generation: 0
    property string probeToken: ""
    signal activated()
    signal calendarActivated()

    function plainTitle(value, limit = 160) {
        if (typeof value !== "string") return ""
        return value.slice(0, 512).replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ")
            .replace(/\s+/g, " ").trim().slice(0, limit).replace(/[\ud800-\udbff]$/, "")
    }

    function probe() {
        generation++
        pending = ({})
        checked = false
        available = false
        probeToken = "probe-" + generation
        if (!transport || !transport.enabled) {
            checked = true
            error = transport && transport.unavailableReason
                ? transport.unavailableReason : "Desktop notifications are unavailable in this runtime."
            return
        }
        error = ""
        let started = false
        try {
            started = transport.execute(probeToken, ["busctl", "--user", "--json=short", "call",
                "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "GetCapabilities"], 3000)
        } catch (_) { }
        if (!started) {
            checked = true
            error = "Desktop notification support could not be checked."
        }
    }

    function announce(runId, revision, activityTitle = "", taskTitle = "") {
        if (typeof runId !== "string" || !runId || typeof revision !== "number"
                || !Number.isInteger(revision) || revision < 0 || revision <= lastClaimRevision)
            return false
        // Consume before dispatch, including unsupported or uncertain delivery.
        // Retrying a notification could replay an already visible desktop alarm.
        lastClaimRevision = revision
        const context = [plainTitle(activityTitle, 72), plainTitle(taskTitle, 72)]
            .filter(title => title !== "").join(" · ")
        return dispatch("completion-" + generation + "-" + revision, "timer",
            context ? qsTr("Finished: %1").arg(plainTitle(context)) : qsTr("Time's up"))
    }

    function announceCalendar(occurrenceId, startEpoch, title) {
        if (typeof occurrenceId !== "string" || !occurrenceId || !Number.isFinite(startEpoch)) return false
        const key = occurrenceId + "/" + startEpoch
        if (Object.prototype.hasOwnProperty.call(calendarClaims, key)) return false
        // Separate dedupe domains: a calendar reminder never consumes a timer
        // revision. Persistent cross-process dedupe belongs to the feed cache.
        calendarClaims[key] = startEpoch
        for (const previous in calendarClaims) {
            if (calendarClaims[previous] < startEpoch - 7 * 24 * 60 * 60) delete calendarClaims[previous]
        }
        return dispatch("calendar-" + generation + "-" + key, "calendar",
            qsTr("Starting: %1").arg(plainTitle(title) || qsTr("Untitled event")))
    }

    function dispatch(token, destination, title) {
        if (!checked || !available || !transport) {
            error = qsTr("Desktop notification unavailable; this reminder will not be announced later.")
            if (destination === "calendar") calendarDeliveryError = error
            return false
        }
        pending[token] = destination
        const icon = decodeURIComponent(Qt.resolvedUrl("timer-notification.svg").toString().replace(/^file:\/\//, ""))
        const action = destination === "calendar" ? qsTr("Open Today") : qsTr("Open timer")
        // argv is executed directly, and -- keeps titles from becoming options.
        // The body stays empty: no diary text, calendar descriptions or markup.
        const command = ["notify-send", "--app-name=Daymark", "--urgency=normal",
            "--icon=" + icon, "--transient", "--hint=boolean:suppress-sound:true",
            "--wait", "--action=default=" + action, "--", title, ""]
        let started = false
        try { started = transport.execute(token, command, 0) } catch (_) { }
        if (!started) {
            delete pending[token]
            error = "The desktop notification could not start. It will not be retried."
            if (destination === "calendar") calendarDeliveryError = error
            return false
        }
        error = ""
        if (destination === "calendar") calendarDeliveryError = ""
        return true
    }

    function finish(token, output, failure) {
        if (token === probeToken) {
            probeToken = ""
            checked = true
            if (failure) {
                error = "Desktop notifications are unavailable: " + plainTitle(failure)
                return
            }
            try {
                const response = JSON.parse(output)
                const capabilities = response.type === "as" && response.data && response.data[0]
                available = Array.isArray(capabilities) && capabilities.indexOf("actions") !== -1
                    && capabilities.indexOf("icon-static") !== -1
            } catch (_) {
                available = false
            }
            if (!available)
                error = qsTr("The desktop notification service does not support notification icons and activation.")
            return
        }
        if (!pending[token])
            return
        const destination = pending[token]
        delete pending[token]
        if (failure) {
            error = "Desktop notification delivery was not confirmed. It will not be retried. " + plainTitle(failure)
            if (destination === "calendar") calendarDeliveryError = error
            return
        }
        const action = output.trim()
        if (action === "default") {
            if (destination === "calendar") calendarActivated()
            else activated()
        } else if (action !== "") {
            error = "The desktop notification returned an unrecognized action."
            if (destination === "calendar") calendarDeliveryError = error
        }
    }

    property Connections transportSignals: Connections {
        target: root.transport
        function onFinished(token, output, failure) { root.finish(token, output, failure) }
    }
    onTransportChanged: probe()
    Component.onCompleted: {
        if (!checked && probeToken === "")
            probe()
    }
}
