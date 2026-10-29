import QtQuick

// Only a committed backend claim enters here; visual countdown ticks never do.
QtObject {
    id: root
    property var transport: null
    property bool checked: false
    property bool available: false
    property string error: ""
    property int lastClaimRevision: -1
    property var pending: ({})
    property int generation: 0
    property string probeToken: ""
    signal activated()

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
        if (!transport.execute(probeToken, ["busctl", "--user", "--json=short", "call",
                "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "GetCapabilities"], 3000)) {
            checked = true
            error = "Desktop notification support could not be checked."
        }
    }

    function announce(runId, revision) {
        if (typeof runId !== "string" || !runId || typeof revision !== "number"
                || !Number.isInteger(revision) || revision < 0 || revision <= lastClaimRevision)
            return false
        // Consume before dispatch, including unsupported or uncertain delivery.
        // Retrying a notification could replay an already visible desktop alarm.
        lastClaimRevision = revision
        if (!checked || !available || !transport) {
            error = "Desktop notification unavailable; this completion will not be announced later."
            return false
        }
        const token = "completion-" + generation + "-" + revision
        pending[token] = true
        const icon = decodeURIComponent(Qt.resolvedUrl("timer-notification.svg").toString().replace(/^file:\/\//, ""))
        const command = ["notify-send", "--app-name=Daymark", "--urgency=normal",
            "--icon=" + icon, "--transient", "--hint=boolean:suppress-sound:true",
            "--wait", "--action=default=Open timer", "Time's up", ""]
        if (!transport.execute(token, command, 0)) {
            delete pending[token]
            error = "The desktop notification could not start. It will not be retried."
            return false
        }
        error = ""
        return true
    }

    function finish(token, output, failure) {
        if (token === probeToken) {
            probeToken = ""
            checked = true
            if (failure) {
                error = "Desktop notifications are unavailable: " + failure
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
                error = "The desktop notification service does not support timer icons and activation."
            return
        }
        if (!pending[token])
            return
        delete pending[token]
        if (failure) {
            error = "Desktop notification delivery was not confirmed. It will not be retried. " + failure
            return
        }
        const action = output.trim()
        if (action === "default")
            activated()
        else if (action !== "")
            error = "The desktop notification returned an unrecognized action."
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
