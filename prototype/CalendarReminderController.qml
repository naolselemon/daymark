import QtQuick

// Observe cached instants locally; the helper is called only for due claims.
// CalendarController owns date/timezone reprojection even without notifications.
QtObject {
    id: root
    required property var calendar
    property bool enabled: true
    property var now: () => Date.now()
    property bool automatic: true
    readonly property bool ready: enabled && calendar && calendar.loaded
        && calendar.configured && calendar.info.enabled && !calendar.suspended
    property real lastTick: now()
    property var upcoming: []
    property int nextEvent: 0
    property bool awaitingClaim: false
    property real claimStamp: 0
    property real claimFloor: 0
    property var queuedFloor: null
    signal reminderClaimed(string occurrenceId, real startEpoch, string title)

    function rebuild() {
        nextEvent = 0
        upcoming = ready ? calendar.reminderEvents.filter(event => !event.allDay
            && Number.isFinite(event.startEpoch) && event.startEpoch * 1000 > lastTick)
            .slice().sort((left, right) => left.startEpoch - right.startEpoch) : []
    }
    function reset() {
        lastTick = now()
        awaitingClaim = false
        queuedFloor = null
        rebuild()
    }
    function requestClaim(floor, stamp) {
        claimStamp = stamp
        claimFloor = floor
        awaitingClaim = true
        if (!calendar.claimReminders(floor)) awaitingClaim = false
    }
    function tick() {
        if (!ready) return
        const stamp = now()
        const previous = lastTick
        const gap = stamp - previous
        lastTick = stamp
        if (gap < 0 || gap > 2000) {
            // Launch, sleep, disabled time and wall-clock jumps never replay a
            // backlog. The next genuinely future event can still be announced.
            awaitingClaim = false
            queuedFloor = null
            rebuild()
        } else {
            let due = false
            while (nextEvent < upcoming.length && upcoming[nextEvent].startEpoch * 1000 <= stamp) {
                if (upcoming[nextEvent].startEpoch * 1000 > previous) due = true
                nextEvent++
            }
            if (due) {
                if (awaitingClaim) {
                    if (queuedFloor === null) queuedFloor = previous / 1000
                } else requestClaim(previous / 1000, stamp)
            }
        }
    }
    function acceptClaims(claims, floor) {
        if (!awaitingClaim || floor !== claimFloor) return
        awaitingClaim = false
        const nextFloor = queuedFloor
        queuedFloor = null
        const stamp = now()
        const age = stamp - claimStamp
        const gap = stamp - lastTick
        if (!ready || age < 0 || age > 15000 || gap < 0 || gap > 2000) return
        for (const claim of claims) {
            const lateness = stamp - claim.startEpoch * 1000
            if (claim.startEpoch > claimFloor && lateness >= 0 && lateness <= 15000)
                reminderClaimed(claim.id, claim.startEpoch, claim.title)
        }
        if (nextFloor !== null) requestClaim(nextFloor, stamp)
    }

    onReadyChanged: reset()
    property Connections calendarSignals: Connections {
        target: root.calendar
        function onReminderEventsChanged() { root.rebuild() }
        function onReminderClaimsFinished(claims, floor) { root.acceptClaims(claims, floor) }
    }
    property Timer heartbeat: Timer {
        interval: 1000
        repeat: true
        running: root.ready && root.automatic
        onTriggered: root.tick()
    }
    Component.onCompleted: reset()
}
