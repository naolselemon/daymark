import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "CalendarRecovery"
    when: true
    property var controller
    property var channel
    readonly property real clock: 1803859200000
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
            events: configured ? [{id: "synthetic", title: "Synthetic event", startDate: "2026-10-29",
                endDate: "2026-10-29", allDay: true, startTime: "", endTime: "", endTimeDate: ""}] : []};
    }
    function init() {
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
}
