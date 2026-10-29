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
            property string operation: ""
            property var requestArgs: null
            property string identity: ""
            function newRequestId() { return "projection-" + (++sequence); }
            function request(op, args, callback, requestId) {
                reads++;
                operation = op;
                requestArgs = args;
                identity = requestId;
                pending = callback;
                return requestId;
            }
            function replyState(state) {
                const callback = pending;
                pending = null;
                callback(true, state, {});
            }
            function fail(code) {
                const callback = pending;
                pending = null;
                callback(false, null, {code: code, message: "Synthetic save failure"});
            }
            function reply(remaining) {
                replyState({status: "running", revision: 1, durationSeconds: 60,
                    remainingExact: remaining, remainingSeconds: Math.ceil(remaining),
                    muted: true, recovery: "", sound: false});
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
    function finishedState(extra) {
        return Object.assign({status: "finished", revision: 2, durationSeconds: 60,
            remainingExact: 0, remainingSeconds: 0, muted: true, recovery: "", sound: false,
            runId: "synthetic-run", activityId: "synthetic-activity", taskId: "synthetic-task",
            activityTitle: "Synthetic learning", taskTitle: "Ownership", targetError: "",
            logPending: false, logSaved: false, logPayload: null}, extra || {});
    }
    function attachFinished() {
        controller.projectionStamp = Date.now();
        controller.refresh();
        source.replyState(finishedState());
        source.reads = 0;
    }
    function test_committed_muted_completion_announces_but_projection_does_not() {
        let claims = [];
        controller.completionClaimed.connect((runId, revision) => claims.push([runId, revision]));
        controller.projectionStamp = Date.now();
        controller.remainingExact = 0;
        compare(claims.length, 0);
        controller.refresh();
        source.replyState(finishedState({notify: true}));
        compare(claims.length, 1);
        compare(claims[0][0], "synthetic-run");
        compare(claims[0][1], 2);
        controller.refresh();
        source.replyState(finishedState({notify: false}));
        compare(claims.length, 1);
    }
    function test_reconciliation_suppresses_completion_notice() {
        let claims = 0;
        controller.completionClaimed.connect(() => claims++);
        controller.projectionStamp = Date.now();
        controller.refresh();
        controller.reconcileNeeded = true;
        source.replyState(finishedState({notify: true}));
        compare(claims, 0);
        tryCompare(source, "reads", 2);
        source.replyState(finishedState({notify: false}));
        compare(claims, 0);
    }
    function test_delayed_reply_does_not_become_a_late_alarm() {
        let claims = 0;
        controller.completionClaimed.connect(() => claims++);
        controller.projectionStamp = Date.now();
        controller.refresh();
        // Projection ticks keep their timestamp fresh while the helper stalls.
        wait(3100);
        controller.projectionStamp = Date.now();
        controller.reconcileNeeded = false;
        source.replyState(finishedState({notify: true}));
        compare(claims, 0);
        compare(controller.status, "finished");
    }
    function test_target_changes_require_idle_and_start_carries_selection() {
        verify(!controller.selectTarget("other", ""));
        controller.status = "paused";
        verify(!controller.selectTarget("other", ""));
        controller.status = "idle";
        verify(controller.selectTarget("synthetic-activity", "synthetic-task"));
        controller.start(90);
        compare(source.operation, "countdown_start");
        compare(source.requestArgs.activityId, "synthetic-activity");
        compare(source.requestArgs.taskId, "synthetic-task");
        compare(source.requestArgs.seconds, 90);
        verify(controller.busy);
    }
    function test_save_freezes_intent_and_callback_requires_confirmed_entry() {
        attachFinished();
        const args = {runId: controller.runId, activityId: controller.activityId,
            taskIds: [controller.taskId], date: "2026-10-29", note: "", done: false};
        let accepted = false;
        controller.saveEntry(args, function(ok, result) {
            accepted = ok;
            compare(result.activityId, args.activityId);
            compare(result.sessionId, "synthetic-entry");
        });
        compare(source.operation, "countdown_log");
        verify(controller.logPending);
        verify(!accepted);
        controller.reset();
        compare(source.reads, 1);
        source.replyState(finishedState({revision: 4, logSaved: true,
            entry: {activityId: args.activityId, sessionId: "synthetic-entry"}}));
        verify(accepted);
        verify(controller.logSaved);
        verify(!controller.logPending);
    }
    function test_ambiguous_failure_reloads_durable_pending_payload_and_blocks_changed_retry() {
        attachFinished();
        const payload = {activityId: controller.activityId, taskIds: [controller.taskId],
            date: "2026-10-29", note: "Synthetic retained draft", done: false};
        const args = Object.assign({runId: controller.runId}, payload);
        let failed = false;
        controller.saveEntry(args, function(ok) { failed = !ok; });
        source.fail("storage");
        verify(failed);
        tryCompare(source, "reads", 2);
        compare(source.operation, "countdown_status");
        source.replyState(finishedState({revision: 3, logPending: true, logPayload: payload}));
        verify(controller.logPending);
        controller.reset();
        compare(source.reads, 2);
        let conflict = false;
        controller.saveEntry(Object.assign({}, args, {note: "Changed"}), function(ok, result, error) {
            conflict = !ok && error.code === "conflict";
        });
        verify(conflict);
        compare(source.reads, 2);
        controller.saveEntry(args, function() {});
        compare(source.operation, "countdown_log");
        compare(source.requestArgs.note, payload.note);
        compare(source.reads, 3);
    }
}
