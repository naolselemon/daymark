import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "CalendarRecovery"
    when: true
    property var controller
    property var channel
    property real clock: 1803859200000
    Component { id: controllerFactory; Daymark.CalendarController {} }
    Component {
        id: channelFactory
        QtObject {
            property var pending: null
            property var operations: []
            property bool canceling: false
            signal finished(string response, string transportError)
            function send(payload) {
                if (pending) return false;
                pending = JSON.parse(payload);
                operations = operations.concat([pending.op]);
                return true;
            }
            function reply(result) {
                const job = pending;
                pending = null;
                finished(JSON.stringify({protocol: 1, requestId: job.requestId, ok: true, result: result}), "");
            }
            function fail(code) {
                const job = pending;
                pending = null;
                finished(JSON.stringify({protocol: 1, requestId: job.requestId, ok: false,
                    error: {code: code, message: "Synthetic backend failure"}}), "");
            }
            function loseReply() { pending = null; finished("", "Private URL must not be displayed"); }
            function cancel() { canceling = true; }
        }
    }
    function state(configured) {
        return {configured: configured, enabled: configured, name: configured ? "Synthetic calendar" : "",
            lastCheckedAt: clock / 1000, lastSuccessAt: clock / 1000, error: "",
            windowStart: "2026-10-01", windowEnd: "2026-11-30",
            reminderDate: Qt.formatDate(new Date(clock), "yyyy-MM-dd"), reminderEvents: [],
            events: configured ? [{id: "synthetic", title: "Synthetic event", startDate: "2026-10-29",
                endDate: "2026-10-29", allDay: true, startEpoch: null,
                startTime: "", endTime: "", endTimeDate: ""}] : []};
    }
    function init() {
        clock = 1803859200000;
        channel = createTemporaryObject(channelFactory, testCase);
        controller = createTemporaryObject(controllerFactory, testCase, {
            transport: channel, now: () => testCase.clock, viewDate: "2026-10-29"
        });
        tryVerify(() => channel.pending !== null);
        channel.reply(state(true));
        tryCompare(controller, "loaded", true);
    }
    function test_concurrent_disconnect_removes_stale_events_after_conflict() {
        verify(controller.refresh());
        channel.fail("conflict");
        tryVerify(() => channel.pending !== null);
        compare(channel.pending.op, "calendar_status");
        channel.reply(state(false));
        compare(controller.configured, false);
        compare(controller.events, []);
        verify(!controller.refresh());
    }
    function test_lost_connection_reply_reconciles_without_replaying_write() {
        controller.info = state(false);
        verify(controller.configure("https://calendar.google.com/calendar/ical/synthetic/basic.ics", "Synthetic calendar"));
        channel.loseReply();
        tryVerify(() => channel.pending !== null);
        compare(channel.pending.op, "calendar_status");
        channel.reply(state(true));
        compare(controller.configured, true);
        compare(controller.events[0].title, "Synthetic event");
        verify(controller.error !== "");
        verify(controller.error.indexOf("Private URL") === -1);
        compare(channel.operations.filter(op => op === "calendar_configure").length, 1);
    }
    function test_cancellation_waits_for_reaping_then_reconciles_committed_state() {
        verify(controller.disconnectFeed());
        controller.cancel();
        verify(controller.busy);
        verify(channel.canceling);
        compare(channel.pending.op, "calendar_disconnect");
        channel.loseReply();
        tryVerify(() => channel.pending !== null);
        compare(channel.pending.op, "calendar_status");
        channel.reply(state(false));
        compare(controller.configured, false);
        compare(controller.events, []);
        verify(!controller.busy);
    }
    function test_midnight_reprojects_offline_without_any_notification_controller() {
        clock = new Date("2026-10-30T23:59:59").getTime();
        controller.info = state(true);
        controller.projectionKey = controller.localDayZone(clock);
        clock += 1000;
        controller.checkIfDue();
        compare(channel.pending.op, "calendar_status");
        channel.reply(state(true));
        controller.checkIfDue();
        compare(channel.pending, null);
        compare(controller.reminderDate, "2026-10-31");
    }
    function test_due_claim_waits_for_a_browsing_projection_without_losing_its_lower_bound() {
        controller.viewDate = "2030-01-01";
        compare(channel.pending.op, "calendar_status");
        const floor = clock / 1000 - 1;
        verify(controller.claimReminders(floor));
        channel.reply(state(true));
        tryVerify(() => channel.pending !== null);
        compare(channel.pending.op, "calendar_claim");
        compare(channel.pending.args.notBefore, floor);
        channel.reply({claims: []});
        compare(controller.events[0].title, "Synthetic event");
    }
    function test_lost_claim_acknowledgement_is_not_retried() {
        verify(controller.claimReminders(clock / 1000 - 1));
        channel.loseReply();
        compare(channel.pending, null);
        compare(channel.operations.filter(op => op === "calendar_claim").length, 1);
        verify(controller.error !== "");
        verify(controller.error.indexOf("Private URL") === -1);
    }
}
