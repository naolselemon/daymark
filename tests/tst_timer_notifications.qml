import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "TimerDesktopNotifications"
    when: true
    property var controller
    property var transport

    Component { id: controllerFactory; Daymark.TimerNotificationController {} }
    Component {
        id: transportFactory
        QtObject {
            property bool enabled: true
            property string unavailableReason: "Synthetic disabled notification transport"
            property bool accepts: true
            property bool throwOnExecute: false
            property var requests: []
            signal finished(string token, string output, string failure)
            function execute(token, command, timeoutMs) {
                if (throwOnExecute) throw new Error("Synthetic launch failure")
                if (!accepts)
                    return false
                requests = requests.concat([{token: token, command: command, timeoutMs: timeoutMs}])
                return true
            }
        }
    }
    SignalSpy { id: activation; target: testCase.controller; signalName: "activated" }
    SignalSpy { id: calendarActivation; target: testCase.controller; signalName: "calendarActivated" }

    function init() {
        transport = createTemporaryObject(transportFactory, testCase)
        controller = createTemporaryObject(controllerFactory, testCase, {transport: transport})
        activation.clear()
        calendarActivation.clear()
    }
    function enableSupport() {
        const probe = transport.requests[transport.requests.length - 1]
        transport.finished(probe.token, JSON.stringify({type: "as", data: [["actions", "icon-static"]]}), "")
        verify(controller.available)
    }
    function complete(index, output, failure) {
        transport.finished(transport.requests[index].token, output || "", failure || "")
    }
    function test_arrival_never_activates_and_only_a_confirmed_click_returns_to_timer() {
        enableSupport()
        verify(controller.announce("synthetic-run", 2))
        compare(activation.count, 0)
        complete(1, "default\n")
        compare(activation.count, 1)
        complete(1, "default\n")
        compare(activation.count, 1)
    }
    function test_dismissal_and_unknown_or_failed_actions_never_activate_data() {
        return [{tag: "dismissed", output: "", failure: ""},
            {tag: "unknown action", output: "open\n", failure: ""},
            {tag: "uncertain failure", output: "default\n", failure: "Synthetic uncertain delivery"}]
    }
    function test_dismissal_and_unknown_or_failed_actions_never_activate(data) {
        enableSupport()
        verify(controller.announce("synthetic-run", 2))
        complete(1, data.output, data.failure)
        compare(activation.count, 0)
        verify(!controller.announce("synthetic-run", 2))
        compare(transport.requests.length, 2)
    }
    function test_failed_dispatch_is_consumed_without_later_retry() {
        enableSupport()
        transport.accepts = false
        verify(!controller.announce("synthetic-run", 2))
        verify(controller.error.length > 0)
        transport.accepts = true
        verify(!controller.announce("synthetic-run", 2))
        compare(transport.requests.length, 1)
        verify(controller.announce("synthetic-next-run", 4))
    }
    function test_unavailable_support_never_queues_a_late_alarm() {
        verify(!controller.announce("synthetic-run", 2))
        compare(transport.requests.length, 1)
        enableSupport()
        verify(controller.error.length > 0) // A skipped completion remains explicit.
        verify(!controller.announce("synthetic-run", 2))
        compare(transport.requests.length, 1)
        verify(controller.announce("synthetic-next-run", 4))
    }
    function test_missing_support_is_explicit_and_does_not_fake_delivery_data() {
        return [{tag: "missing daemon", output: "", failure: "Synthetic service unavailable"},
            {tag: "missing actions", output: '{"type":"as","data":[["icon-static"]]}', failure: ""},
            {tag: "missing icon", output: '{"type":"as","data":[["actions"]]}', failure: ""},
            {tag: "malformed reply", output: "not-json", failure: ""}]
    }
    function test_missing_support_is_explicit_and_does_not_fake_delivery(data) {
        complete(0, data.output, data.failure)
        verify(controller.checked)
        verify(!controller.available)
        verify(controller.error.length > 0)
        verify(!controller.announce("synthetic-run", 2))
        compare(transport.requests.length, 1)
        compare(activation.count, 0)
    }
    function test_older_claims_do_not_replay_after_newer_completions() {
        enableSupport()
        verify(controller.announce("synthetic-first", 2))
        verify(controller.announce("synthetic-second", 4))
        verify(!controller.announce("synthetic-first", 2))
        compare(transport.requests.length, 3)
        // Each live card has its own action waiter; a new timer does not orphan it.
        complete(2, "default\n")
        complete(1, "default\n")
        compare(activation.count, 2)
    }
    function test_replaced_transport_ignores_old_callbacks() {
        enableSupport()
        verify(controller.announce("synthetic-run", 2))
        const oldTransport = transport
        const oldToken = transport.requests[1].token
        transport = createTemporaryObject(transportFactory, testCase)
        controller.transport = transport
        oldTransport.finished(oldToken, "default\n", "")
        controller.finish(oldToken, "default\n", "")
        compare(activation.count, 0)
        verify(!controller.announce("synthetic-run", 2))
    }
    function test_disabled_preview_never_launches_a_notification_process() {
        transport.enabled = false
        controller.probe()
        verify(controller.checked)
        verify(!controller.available)
        compare(controller.error, transport.unavailableReason)
        verify(!controller.announce("synthetic-run", 2))
        compare(transport.requests.length, 1)
    }
    function test_linked_completion_names_the_target_with_a_bounded_plain_summary_and_empty_body() {
        enableSupport()
        verify(controller.announce("linked-run", 2, "Study <b>QML</b>\n", "--help\u202e ownership"))
        const command = transport.requests[1].command
        const separator = command.indexOf("--")
        verify(separator > 0)
        const summary = command[separator + 1]
        verify(summary.indexOf("Study <b>QML</b>") !== -1)
        verify(summary.indexOf("--help ownership") !== -1)
        verify(summary.indexOf("\n") === -1)
        verify(summary.indexOf("\u202e") === -1)
        compare(command[separator + 2], "")
        verify(controller.announce("long-run", 3, "A".repeat(5000), "T".repeat(5000)))
        verify(transport.requests[2].command[separator + 1].length <= 180)
        verify(transport.requests[2].command[separator + 1].indexOf("T") !== -1)
    }
    function test_calendar_and_timer_dedupe_and_activation_domains_are_independent() {
        enableSupport()
        verify(controller.announceCalendar("occurrence", 1000, "Planning meeting"))
        verify(controller.announce("run", 2, "Learning", "Read notes"))
        verify(!controller.announceCalendar("occurrence", 1000, "Planning meeting"))
        compare(calendarActivation.count, 0)
        compare(activation.count, 0)
        complete(1, "default\n")
        compare(calendarActivation.count, 1)
        compare(activation.count, 0)
        complete(2, "default\n")
        compare(activation.count, 1)
        complete(1, "default\n")
        compare(calendarActivation.count, 1)
    }
    function test_calendar_title_is_not_an_option_or_body_markup() {
        enableSupport()
        verify(controller.announceCalendar("occurrence", 1000, "--app-name=evil\n<b>Meeting</b>"))
        const command = transport.requests[1].command
        const separator = command.indexOf("--")
        verify(command[separator + 1].indexOf("--app-name=evil <b>Meeting</b>") !== -1)
        compare(command[separator + 2], "")
        verify(command.indexOf("--urgency=critical") === -1)
    }
    function test_failed_calendar_delivery_is_explicit_and_never_replayed() {
        enableSupport()
        verify(controller.announceCalendar("occurrence", 1000, "Meeting"))
        complete(1, "", "Synthetic delivery error")
        verify(controller.calendarError.length > 0)
        verify(!controller.announceCalendar("occurrence", 1000, "Meeting"))
        compare(calendarActivation.count, 0)
        compare(transport.requests.length, 2)
    }
    function test_probe_and_dispatch_exceptions_are_explicit_without_late_retries() {
        transport.throwOnExecute = true
        controller.probe()
        verify(controller.checked)
        verify(!controller.available)
        verify(controller.calendarError.length > 0)
        transport.throwOnExecute = false
        controller.probe()
        enableSupport()
        transport.throwOnExecute = true
        verify(!controller.announceCalendar("occurrence", 1000, "Meeting"))
        verify(controller.calendarError.length > 0)
        transport.throwOnExecute = false
        verify(!controller.announceCalendar("occurrence", 1000, "Meeting"))
    }
}
