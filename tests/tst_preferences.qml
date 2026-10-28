import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "PreferencesAcknowledgments"
    when: true
    property var controller
    property var source

    Component {
        id: controllerFactory
        Daymark.PreferencesController {}
    }
    Component {
        id: storeFactory
        QtObject {
            property int calls: 0
            property int sequence: 0
            property var pending: null
            property var state: ({openingPage: "Timer", lastPage: "Timer", onlineQuotes: true,
                                  diaryIdleMinutes: 0, automaticUpdates: false})
            function newRequestId() { return "preferences-" + (++sequence); }
            function request(op, args, callback, requestId) {
                if (pending) throw new Error("Controller dispatched overlapping requests");
                calls++;
                pending = {op: op, args: args, callback: callback, id: requestId};
            }
            function reply() {
                const request = pending;
                pending = null;
                if (request.op === "preferences_set") state = Object.assign({}, state, request.args.changes);
                request.callback(true, Object.assign({}, state), {});
            }
            function fail() {
                const request = pending;
                pending = null;
                request.callback(false, null, {code: "read_only", message: "Synthetic settings write failure."});
            }
        }
    }
    function init() {
        source = createTemporaryObject(storeFactory, testCase);
        controller = createTemporaryObject(controllerFactory, testCase, {store: source});
        tryCompare(source, "calls", 1);
        compare(source.pending.op, "preferences_get");
    }
    function load() {
        source.reply();
        verify(controller.loaded);
        verify(!controller.busy);
    }
    function test_network_fails_closed_until_successful_load() {
        verify(!controller.loaded);
        verify(!controller.onlineQuotes);
        verify(!controller.automaticUpdates);
        const id = source.pending.id;
        source.fail();
        verify(!controller.loaded);
        verify(!controller.onlineQuotes);
        verify(controller.error.length > 0);
        controller.retry();
        compare(source.pending.id, id);
        source.reply();
        verify(controller.loaded);
        verify(controller.onlineQuotes);
        verify(!controller.automaticUpdates);
        compare(controller.error, "");
    }
    function test_explicit_settings_are_only_visible_after_ack() {
        load();
        verify(controller.setValue("openingPage", "Today"));
        compare(controller.openingPage, "Timer");
        verify(controller.busy);
        compare(source.pending.args.changes.openingPage, "Today");
        source.reply();
        compare(controller.openingPage, "Today");
        verify(!controller.busy);
    }
    function test_navigation_coalesces_to_latest_page() {
        load();
        controller.rememberPage("Today");
        controller.rememberPage("History");
        controller.rememberPage("Quotes");
        compare(source.calls, 1);
        compare(controller.lastPage, "Timer");
        tryCompare(source, "calls", 2);
        compare(source.pending.args.changes.lastPage, "Quotes");
        source.reply();
        compare(controller.lastPage, "Quotes");
        wait(300);
        compare(source.calls, 2);
    }
    function test_navigation_cannot_clobber_queued_explicit_change() {
        load();
        controller.setValue("openingPage", "last");
        controller.setValue("diaryIdleMinutes", 5);
        controller.rememberPage("Today");
        controller.rememberPage("Diary");
        wait(300);
        compare(source.calls, 2);
        compare(source.pending.args.changes.openingPage, "last");
        source.reply();
        tryCompare(source, "calls", 3);
        compare(source.pending.args.changes.diaryIdleMinutes, 5);
        compare(controller.diaryIdleMinutes, 0);
        source.reply();
        tryCompare(source, "calls", 4);
        compare(source.pending.args.changes.lastPage, "Diary");
        compare(controller.diaryIdleMinutes, 5);
        source.reply();
        compare(controller.openingPage, "last");
        compare(controller.lastPage, "Diary");
    }
    function test_failed_save_retains_canonical_values_and_explicit_retry() {
        load();
        controller.setValue("onlineQuotes", false);
        const failedId = source.pending.id;
        controller.setValue("automaticUpdates", true);
        controller.rememberPage("Plan");
        source.fail();
        verify(controller.onlineQuotes);
        verify(!controller.automaticUpdates);
        compare(controller.lastPage, "Timer");
        verify(controller.error.length > 0);
        controller.rememberPage("Quotes");
        wait(300);
        compare(source.calls, 2);
        verify(controller.error.length > 0);
        controller.refresh(); // Refresh must not discard a retained failed save.
        compare(source.pending.id, failedId);
        compare(source.pending.args.changes.onlineQuotes, false);
        source.reply();
        verify(!controller.onlineQuotes);
        tryCompare(source, "calls", 4);
        compare(source.pending.args.changes.automaticUpdates, true);
        source.reply();
        tryCompare(source, "calls", 5);
        compare(source.pending.args.changes.lastPage, "Quotes");
        source.reply();
        verify(controller.automaticUpdates);
        compare(controller.error, "");
    }
    function test_failed_navigation_then_latest_navigation_is_not_lost() {
        load();
        controller.rememberPage("Today");
        tryCompare(source, "calls", 2);
        source.fail();
        controller.rememberPage("History");
        wait(300);
        compare(controller.lastPage, "Timer");
        controller.retry();
        source.reply();
        compare(controller.lastPage, "Today");
        tryCompare(source, "calls", 4);
        compare(source.pending.args.changes.lastPage, "History");
        source.reply();
        compare(controller.lastPage, "History");
    }
    function test_navigation_during_initial_load_survives() {
        controller.rememberPage("Plan");
        wait(300);
        compare(source.calls, 1);
        load();
        tryCompare(source, "calls", 2);
        compare(source.pending.args.changes.lastPage, "Plan");
        source.reply();
        compare(controller.lastPage, "Plan");
    }
    function test_malformed_ack_never_enables_network_or_updates_state() {
        const request = source.pending;
        source.pending = null;
        request.callback(true, {onlineQuotes: true, automaticUpdates: true}, {});
        verify(!controller.loaded);
        verify(!controller.onlineQuotes);
        verify(!controller.automaticUpdates);
        verify(controller.error.length > 0);
    }
    function test_invalid_choices_do_not_dispatch() {
        load();
        verify(!controller.setValue("diaryIdleMinutes", true));
        verify(!controller.setValue("automaticUpdates", 1));
        verify(!controller.setValue("openingPage", "Diary"));
        verify(!controller.setValue("muted", true));
        controller.rememberPage("Settings");
        wait(300);
        compare(source.calls, 1);
    }
}
