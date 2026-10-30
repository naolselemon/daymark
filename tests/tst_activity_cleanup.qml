pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "ActivityCleanup"
    width: 620; height: 820
    visible: true; when: windowShown
    property var channel
    property var store
    property var workspace
    property var dialog
    Daymark.Theme {
        id: fixtureTheme
        source: ({background: "#181818", foreground: "#eeeeee", accent: "#aaccaa", urgent: "#ffaaaa",
            radius: 0, family: "sans-serif", scale: 1,
            font: {title: 14, body: 12, heading: 18, display: 22, "display-large": 28},
            spacing: {"control-gap": 8, "panel-padding": 16, "control-padding-y": 8, "control-padding-x": 12, "control-height": 44},
            states: {normal: {fill: "#222222", border: "#777777", width: 1},
                "hover-cursor": {fill: "#333333", border: "#999999", width: 1},
                pressed: {fill: "#333333", border: "#999999", width: 1},
                selected: {fill: "#222222", border: "#555555", width: 1},
                selection: {fill: "#446644", border: "#aaccaa", width: 0},
                focus: {fill: "#333333", border: "#aaccaa", width: 1}}})
    }
    Component { id: storeFactory; Daymark.PersistentStore {} }
    Component { id: dialogFactory; Daymark.ActivityCleanupDialog { theme: fixtureTheme } }
    Component {
        id: workspaceFactory
        QtObject {
            property string cleanupBlockReason: ""
            property var pendingAuth: null
            property int authCount: 0
            property bool freshRequested: false
            property string purpose: ""
            function authorizeDiary(action, title, fresh) {
                authCount++;
                freshRequested = fresh;
                purpose = title;
                pendingAuth = action;
                return false;
            }
            function cancelDiaryAuthentication() { pendingAuth = null; }
            function authenticate() {
                const action = pendingAuth;
                pendingAuth = null;
                if (action) action();
            }
        }
    }
    Component {
        id: transportFactory
        QtObject {
            property int revision: 1
            property var mutations: []
            property var pendingMutation: null
            signal finished(string response, string transportError)
            signal dataChanged()
            function snapshot() {
                return {revision: revision, today: Qt.formatDate(new Date(), "yyyy-MM-dd"),
                    activities: [], sessions: [], dayNotes: {}, events: [], categories: [], projects: [],
                    trash: [], daySummaries: {}, insights: {days: [], byActivity: {}}};
            }
            function send(payload) {
                const job = JSON.parse(payload);
                if (job.op === "reset_today_entries" || job.op === "wipe_activity_data") {
                    mutations = mutations.concat([job]);
                    pendingMutation = job;
                } else Qt.callLater(() => finished(JSON.stringify({protocol: 1, requestId: job.requestId,
                    ok: true, snapshot: snapshot(), result: job.op === "history"
                        ? {sessions: [], notes: [], completions: [], total: 0, hasMore: false} : {}}), ""));
                return true;
            }
            function answer(ok, code) {
                const job = pendingMutation;
                pendingMutation = null;
                if (ok) revision++;
                finished(JSON.stringify({protocol: 1, requestId: job.requestId, ok: ok, snapshot: snapshot(),
                    result: {deletedEntries: 2, deletedActivities: job.op === "wipe_activity_data" ? 1 : 0},
                    error: {code: code || "read_only", message: "SYNTHETIC deletion failure"}}), "");
            }
            function loseReply() {
                pendingMutation = null;
                finished("", "SYNTHETIC unknown deletion result");
            }
        }
    }
    function init() {
        channel = createTemporaryObject(transportFactory, testCase);
        store = createTemporaryObject(storeFactory, testCase, {transport: channel});
        workspace = createTemporaryObject(workspaceFactory, testCase);
        dialog = createTemporaryObject(dialogFactory, testCase, {store: store, workspace: workspace});
        verify(dialog);
        tryVerify(() => store.loaded && !store.busy && !store.historyLoading);
    }
    function cleanup() {
        if (channel.pendingMutation) channel.answer(false);
        dialog.requestDismiss();
        tryVerify(() => !store.busy && !store.historyLoading);
    }
    function begin(operation) {
        dialog.begin(operation || "reset_today_entries");
        tryCompare(dialog, "opened", true);
    }
    function confirm() {
        findChild(dialog, "activityCleanupConfirmation").text = dialog.confirmationPhrase;
        dialog.approve();
    }
    function test_confirmation_then_fresh_authentication_required() {
        begin("wipe_activity_data");
        dialog.approve();
        compare(workspace.authCount, 0);
        findChild(dialog, "activityCleanupConfirmation").text = "wipe all activity data";
        dialog.approve();
        compare(workspace.authCount, 0);
        confirm();
        compare(workspace.authCount, 1);
        verify(workspace.freshRequested);
        verify(workspace.purpose.indexOf("activity") >= 0);
        compare(channel.mutations.length, 0);
        dialog.approve();
        compare(workspace.authCount, 1);
        workspace.authenticate();
        tryVerify(() => channel.mutations.length === 1);
        compare(channel.pendingMutation.op, "wipe_activity_data");
        compare(channel.pendingMutation.args, {expectedRevision: 1});
        verify(dialog.saving);
        verify(!dialog.requestDismiss());
        store.historyOffset = 100;
        store.historyEntries = [{id: "synthetic-old-entry"}];
        channel.answer(true);
        compare(store.historyOffset, 0);
        compare(store.historyEntries.length, 0);
        tryCompare(dialog, "opened", false);
        compare(store.cleanupRetry, null);
        compare(store.records.revision, 2);
    }
    function test_scope_is_captured_local_today_not_selected_journal_date() {
        store.date = "2001-01-01";
        begin();
        const today = Qt.formatDate(new Date(), "yyyy-MM-dd");
        compare(dialog.requestArgs.date, today);
        confirm();
        workspace.authenticate();
        tryVerify(() => channel.pendingMutation !== null);
        compare(channel.pendingMutation.args.date, today);
        channel.answer(true);
    }
    function test_cancellation_invalidates_late_authentication() {
        begin();
        confirm();
        const late = workspace.pendingAuth;
        dialog.authenticationCancelled();
        late();
        compare(channel.mutations.length, 0);
        compare(findChild(dialog, "activityCleanupConfirmation").text, "");
        verify(!dialog.authenticating);
        confirm();
        const afterClose = workspace.pendingAuth;
        verify(dialog.requestDismiss());
        afterClose();
        compare(channel.mutations.length, 0);
        compare(workspace.pendingAuth, null);
    }
    function test_guard_is_rechecked_after_password() {
        begin();
        workspace.cleanupBlockReason = "SYNTHETIC pending draft";
        confirm();
        compare(workspace.authCount, 0);
        workspace.cleanupBlockReason = "";
        confirm();
        workspace.cleanupBlockReason = "SYNTHETIC pending countdown";
        workspace.authenticate();
        compare(channel.mutations.length, 0);
        compare(dialog.error, workspace.cleanupBlockReason);
        verify(!dialog.saving);
    }
    function test_midnight_requires_new_review_not_new_date_deletion() {
        begin();
        dialog.requestArgs = {date: "2001-01-01", expectedRevision: 1};
        confirm();
        compare(workspace.authCount, 0);
        compare(channel.mutations.length, 0);
        verify(dialog.error.indexOf("day changed") >= 0);
        compare(dialog.requestArgs.date, "2001-01-01");
    }
    function test_failure_keeps_dialog_and_requires_new_confirmation_and_auth() {
        begin();
        confirm();
        workspace.authenticate();
        tryVerify(() => channel.pendingMutation !== null);
        channel.answer(false, "read_only");
        verify(dialog.opened);
        verify(!dialog.saving);
        compare(dialog.error, "SYNTHETIC deletion failure");
        compare(store.records.revision, 1);
        compare(store.cleanupRetry, null);
        dialog.approve();
        compare(workspace.authCount, 1);
        compare(channel.mutations.length, 1);
        confirm();
        compare(workspace.authCount, 2);
        compare(channel.mutations.length, 1);
    }
    function test_unknown_result_retains_exact_receipt_across_reopen() {
        begin();
        confirm();
        workspace.authenticate();
        tryVerify(() => channel.pendingMutation !== null);
        const original = channel.pendingMutation;
        channel.loseReply();
        compare(store.cleanupRetry.id, original.requestId);
        compare(channel.mutations.length, 1);
        channel.revision = 2;
        store.records = Object.assign({}, store.records, {revision: 2});
        dialog.requestDismiss();
        tryCompare(dialog, "opened", false);
        begin("wipe_activity_data");
        compare(dialog.operation, "reset_today_entries");
        compare(dialog.requestArgs, original.args);
        confirm();
        compare(workspace.authCount, 2);
        compare(channel.mutations.length, 1);
        workspace.authenticate();
        tryVerify(() => channel.mutations.length === 2);
        compare(channel.pendingMutation, original);
        channel.answer(true);
        tryCompare(dialog, "opened", false);
        compare(store.cleanupRetry, null);
    }
    function test_store_refuses_dirty_notes() {
        let failure = "";
        store.editNote(store.today, "SYNTHETIC draft");
        store.noteTimer.stop();
        verify(!store.cleanupActivityData("wipe_activity_data", {expectedRevision: 1},
            (ok, result, error) => { failure = error.code; }));
        compare(failure, "busy");
        compare(channel.mutations.length, 0);
        verify(store.hasUnsavedNotes);
    }
    function test_store_refuses_busy_queue() {
        let failure = "";
        store.reload();
        verify(!store.cleanupActivityData("wipe_activity_data", {expectedRevision: 1},
            (ok, result, error) => { failure = error.code; }));
        compare(failure, "busy");
        compare(channel.mutations.length, 0);
    }
    function test_revision_is_never_rebased_after_review_data() {
        return [{tag: "before authentication", duringAuth: false}, {tag: "during authentication", duringAuth: true}];
    }
    function test_revision_is_never_rebased_after_review(data) {
        begin("wipe_activity_data");
        if (data.duringAuth) confirm();
        store.records = Object.assign({}, store.records, {revision: 2});
        if (data.duringAuth) workspace.authenticate();
        else confirm();
        compare(dialog.requestArgs.expectedRevision, 1);
        compare(channel.mutations.length, 0);
        verify(dialog.error.indexOf("journal changed") >= 0);
        compare(workspace.authCount, data.duringAuth ? 1 : 0);
    }
    function test_midnight_during_authentication_refuses_execution() {
        begin();
        confirm();
        dialog.requestArgs = {date: "2001-01-01", expectedRevision: 1};
        workspace.authenticate();
        compare(channel.mutations.length, 0);
        verify(dialog.error.indexOf("day changed") >= 0);
    }
}
