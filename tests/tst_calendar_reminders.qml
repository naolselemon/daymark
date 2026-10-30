import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "CalendarStartReminders"
    when: true
    property real clock: 1000000
    property var calendar
    property var reminders
    Component { id: reminderFactory; Daymark.CalendarReminderController {} }
    Component {
        id: calendarFactory
        QtObject {
            property bool loaded: true
            property bool configured: true
            property bool suspended: false
            property bool busy: false
            property var info: ({enabled: true})
            property var reminderEvents: []
            property string viewDate: "2030-01-01"
            property var events: []
            property var requests: []
            signal reminderClaimsFinished(var claims, real notBefore)
            function claimReminders(floor) {
                requests = requests.concat([floor])
                return true
            }
        }
    }
    SignalSpy { id: delivered; target: testCase.reminders; signalName: "reminderClaimed" }
    function event(id, milliseconds, allDay = false) {
        return {id: id, startEpoch: allDay ? null : milliseconds / 1000, allDay: allDay, title: "Named " + id}
    }
    function init() {
        clock = 1000000
        calendar = createTemporaryObject(calendarFactory, testCase, {reminderEvents: [
            event("missed", clock - 1000), event("all-day", clock, true),
            event("due", clock + 1000), event("future", clock + 10000)]})
        reminders = createTemporaryObject(reminderFactory, testCase, {
            calendar: calendar, now: () => testCase.clock, automatic: false})
        delivered.clear()
    }
    function tick(milliseconds) {
        clock += milliseconds
        reminders.tick()
    }
    function claim(id, milliseconds, floor = calendar.requests[calendar.requests.length - 1]) {
        calendar.reminderClaimsFinished([{id: id, startEpoch: milliseconds / 1000, title: "Named " + id}], floor)
    }
    function test_only_current_due_named_event_delivers_while_browsing_a_distant_day() {
        tick(500)
        compare(calendar.requests.length, 0)
        tick(500)
        compare(calendar.requests.length, 1)
        claim("due", 1001000)
        compare(delivered.count, 1)
        compare(Array.from(delivered.signalArguments[0]), ["due", 1001, "Named due"])
        claim("due", 1001000)
        tick(1000)
        compare(delivered.count, 1)
        compare(calendar.requests.length, 1)
        compare(calendar.viewDate, "2030-01-01")
    }
    function test_refresh_replaces_removed_and_rescheduled_starts() {
        calendar.reminderEvents = [event("moved", clock + 3000)]
        tick(1000)
        compare(calendar.requests.length, 0)
        tick(1000)
        tick(1000)
        compare(calendar.requests.length, 1)
        claim("moved", clock)
        compare(delivered.signalArguments[0][0], "moved")
    }
    function test_resume_discards_missed_events_but_keeps_future_starts() {
        tick(5000)
        compare(calendar.requests.length, 0)
        for (let index = 0; index < 5; index++) tick(1000)
        compare(calendar.requests.length, 1)
        claim("future", clock)
        compare(delivered.signalArguments[0][0], "future")
    }
    function test_restart_after_start_does_not_claim_a_backlog() {
        tick(1500)
        reminders.destroy()
        reminders = createTemporaryObject(reminderFactory, testCase, {
            calendar: calendar, now: () => testCase.clock, automatic: false})
        const before = calendar.requests.length
        tick(1000)
        compare(calendar.requests.length, before)
    }
    function test_latency_while_heartbeats_continue_is_not_mistaken_for_resume() {
        tick(1000)
        for (let index = 0; index < 5; index++) tick(1000)
        claim("due", 1001000)
        compare(delivered.count, 1)
    }
    function test_late_reply_after_sleep_does_not_deliver_or_replay() {
        tick(1000)
        clock += 5000
        claim("due", 1001000)
        compare(delivered.count, 0)
        reminders.tick()
        compare(calendar.requests.length, 1)
    }
    function test_disabled_or_disconnected_observers_never_deliver_pending_claims_data() {
        return [{tag: "plugin disabled", disconnect: false}, {tag: "feed disconnected", disconnect: true}]
    }
    function test_disabled_or_disconnected_observers_never_deliver_pending_claims(data) {
        tick(1000)
        if (data.disconnect) calendar.configured = false
        else reminders.enabled = false
        claim("due", 1001000)
        compare(delivered.count, 0)
        tick(1000)
        compare(calendar.requests.length, 1)
    }
    function test_lost_or_failed_claim_is_consumed_without_retry() {
        tick(1000)
        calendar.reminderClaimsFinished([], calendar.requests[0])
        tick(1000)
        compare(calendar.requests.length, 1)
        compare(delivered.count, 0)
    }
    function test_next_start_is_not_lost_while_previous_claim_is_inflight() {
        calendar.reminderEvents = [event("first", clock + 1000), event("second", clock + 2000)]
        tick(1000)
        tick(1000)
        claim("first", 1001000)
        compare(calendar.requests.length, 2)
        claim("second", 1002000)
        compare(delivered.count, 2)
        compare(delivered.signalArguments[1][0], "second")
    }
    function test_old_reply_after_resume_does_not_consume_a_new_start() {
        tick(1000)
        const oldFloor = calendar.requests[0]
        tick(5000)
        for (let index = 0; index < 4; index++) tick(1000)
        compare(calendar.requests.length, 2)
        claim("due", 1001000, oldFloor)
        claim("future", 1010000)
        compare(delivered.count, 1)
        compare(delivered.signalArguments[0][0], "future")
    }
}
