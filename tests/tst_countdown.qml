import QtQuick
import QtTest
import "../prototype" as Daymark

// Projection tests only; durable deadlines/claims use real SQLite in Python.
TestCase {
    id: testCase
    name: "CountdownProjection"
    when: true
    property var controller
    property var source

    Component {
        id: controllerFactory
        Daymark.CountdownController {}
    }
    Component {
        id: storeFactory
        QtObject {
            property int reads: 0
            property int sequence: 0
            property var pending: null
            function newRequestId() { return "projection-" + (++sequence); }
            function request(op, args, callback, requestId) {
                reads++;
                pending = callback;
                return requestId;
            }
            function reply(remaining) {
                const callback = pending;
                pending = null;
                callback(true, {status: "running", revision: 1, durationSeconds: 60,
                    remainingExact: remaining, remainingSeconds: Math.ceil(remaining),
                    muted: true, recovery: "", sound: false}, {});
            }
        }
    }
    function init() {
        source = createTemporaryObject(storeFactory, testCase);
        controller = createTemporaryObject(controllerFactory, testCase, {store: source});
        tryCompare(source, "reads", 1);
        source.reply(60);
        controller.projectionStamp = 100000;
        source.reads = 0;
    }
    function test_short_frame_delays_use_elapsed_projection_without_helpers() {
        controller.project(100750);
        compare(controller.remainingExact, 59.25);
        controller.project(101250);
        compare(controller.remainingExact, 58.75);
        compare(source.reads, 0);
    }
    function test_discontinuity_data() {
        return [{tag: "wake", now: 130000}, {tag: "clock backward", now: 99000}];
    }
    function test_discontinuity(data) {
        controller.project(data.now);
        compare(source.reads, 1);
        compare(controller.remainingExact, 60); // Never infer elapsed from the jump.
        source.reply(23);
        compare(controller.remainingExact, 23);
        verify(Math.abs(controller.projectionStamp - Date.now()) < 1000);
    }
    function test_busy_discontinuity_reconciles_after_inflight_reply() {
        controller.refresh();
        compare(source.reads, 1);
        controller.project(130000);
        compare(source.reads, 1);
        verify(controller.reconcileNeeded);
        source.reply(55);
        tryCompare(source, "reads", 2);
        source.reply(21);
        compare(controller.remainingExact, 21);
        verify(!controller.reconcileNeeded);
    }
    function test_periodic_refresh_uses_elapsed_not_frame_count() {
        for (let i = 1; i <= 10; ++i) controller.project(100000 + i * 1000);
        compare(source.reads, 1);
        compare(controller.remainingExact, 50);
    }
    function test_projected_zero_requires_backend_completion() {
        controller.remainingExact = 0.5;
        controller.project(100750);
        compare(controller.remainingSeconds, 0);
        compare(controller.status, "running");
        compare(source.reads, 1);
    }
}
