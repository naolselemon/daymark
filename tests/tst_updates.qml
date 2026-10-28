import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "UpdateScheduling"
    when: true
    property var controller
    property var channel
    property var preferences
    property real clock: 1000000000
    readonly property string candidate: "1234567890123456789012345678901234567890"

    Component { id: controllerFactory; Daymark.UpdateController {} }
    Component {
        id: preferencesFactory
        QtObject {
            property bool loaded: true
            property bool automaticUpdates: false
        }
    }
    Component {
        id: channelFactory
        QtObject {
            property var pending: null
            property var operations: []
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
            function fail(message) {
                const job = pending;
                pending = null;
                finished(JSON.stringify({protocol: 1, requestId: job.requestId, ok: false,
                    error: {code: "network", message: message}}), "");
            }
            function loseReply() { pending = null; finished("", "Update response was interrupted."); }
        }
    }
    function state(changes) {
        return Object.assign({installedVersion: "0.2.0", availableVersion: "", availableCommit: "",
            lastAttemptAt: clock, lastCheckedAt: clock, phase: "current", supported: true, message: ""}, changes || {});
    }
    function init() {
        clock = 1000000000;
        channel = createTemporaryObject(channelFactory, testCase);
        preferences = createTemporaryObject(preferencesFactory, testCase);
        controller = createTemporaryObject(controllerFactory, testCase, {
            transport: channel, preferences: preferences, now: () => testCase.clock, canApply: true
        });
        tryVerify(() => channel.pending !== null);
        channel.reply(state());
        tryCompare(controller, "loaded", true);
    }
    function test_persisted_attempt_controls_daily_due_boundary_data() {
        return [
            {tag: "not yet due", elapsed: 86400000 - 1, due: false},
            {tag: "exactly due", elapsed: 86400000, due: true},
            {tag: "one catch-up after sleep", elapsed: 5 * 86400000, due: true},
            {tag: "clock moved backward", elapsed: -1000, due: true}
        ];
    }
    function test_persisted_attempt_controls_daily_due_boundary(data) {
        clock += data.elapsed;
        preferences.automaticUpdates = true;
        controller.checkIfDue();
        compare(channel.operations.filter(op => op === "update_check").length, data.due ? 1 : 0);
        if (data.due) {
            controller.checkIfDue();
            compare(channel.operations.filter(op => op === "update_check").length, 1);
            channel.reply(state());
            controller.checkIfDue();
            compare(channel.operations.filter(op => op === "update_check").length, 1);
        }
    }
    function test_disabled_schedule_does_not_disable_manual_check() {
        clock += 10 * 86400000;
        controller.checkIfDue();
        compare(channel.operations, ["update_status"]);
        verify(controller.check());
        compare(channel.pending.op, "update_check");
        channel.reply(state());
        verify(!controller.busy);
    }
    function test_failed_check_refreshes_attempt_without_network_retry() {
        preferences.automaticUpdates = true;
        clock += 86400000;
        controller.checkIfDue();
        channel.fail("GitHub could not be reached.");
        tryVerify(() => channel.pending !== null);
        compare(channel.pending.op, "update_status");
        channel.reply(state({lastCheckedAt: clock - 86400000}));
        controller.checkIfDue();
        compare(channel.operations.filter(op => op === "update_check").length, 1);
        compare(controller.error, "GitHub could not be reached.");
        compare(controller.info.lastCheckedAt, clock - 86400000);
    }
    function test_install_requires_current_commit_and_safe_workspace() {
        controller.info = state({phase: "ready", availableVersion: "0.3.0", availableCommit: candidate});
        verify(!controller.applyApproved("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        controller.canApply = false;
        controller.blockReason = "Save your draft first.";
        verify(!controller.applyApproved(candidate));
        compare(channel.operations, ["update_status"]);
        compare(controller.error, "Save your draft first.");
        controller.canApply = true;
        verify(controller.applyApproved(candidate));
        verify(controller.applying);
        verify(!controller.applyApproved(candidate));
        compare(channel.operations.filter(op => op === "update_install").length, 1);
        channel.reply(state({phase: "installing", availableVersion: "0.3.0", availableCommit: candidate}));
        verify(controller.applying);
    }
    function test_lost_install_reply_never_replays_installation() {
        controller.info = state({phase: "ready", availableVersion: "0.3.0", availableCommit: candidate});
        verify(controller.applyApproved(candidate));
        channel.loseReply();
        verify(controller.applying);
        tryVerify(() => channel.pending !== null);
        compare(channel.pending.op, "update_status");
        channel.reply(state({phase: "installing", availableVersion: "0.3.0", availableCommit: candidate}));
        verify(controller.applying);
        compare(channel.operations.filter(op => op === "update_install").length, 1);
        verify(!controller.check());
    }
}
