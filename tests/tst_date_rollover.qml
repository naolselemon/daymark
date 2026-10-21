import QtQuick
import QtTest
import "../prototype" as Daymark
import "../prototype/Display.js" as Display

TestCase {
    id: testCase
    name: "DateRollover"
    when: true
    property var store
    property var source
    property string sampledDay

    Component {
        id: storeFactory
        Daymark.PersistentStore {}
    }
    Component {
        id: transportFactory
        QtObject {
            property string snapshotDay: "2030-12-31"
            property bool hold: false
            property bool fail: false
            property var held: []
            property int reads: 0
            signal finished(string response, string error)
            signal dataChanged()
            function send(payload) {
                const request = JSON.parse(payload);
                reads++;
                if (hold) held = held.concat([request]);
                else Qt.callLater(() => reply(request));
                return true;
            }
            function reply(request) {
                const snapshot = {
                    revision: 1, today: snapshotDay, activities: [], sessions: [],
                    dayNotes: {}, events: [], categories: [], projects: [], trash: [],
                    daySummaries: {}, insights: {days: [], byActivity: {}}
                };
                const result = request.op === "history"
                    ? {sessions: [], notes: [], completions: [], total: 0, hasMore: false} : {};
                finished(JSON.stringify({protocol: 1, requestId: request.requestId, ok: !fail,
                    snapshot: snapshot, result: result,
                    error: {code: "read_only", message: "SYNTHETIC read failure"}}), "");
            }
        }
    }
    function init() {
        sampledDay = "2030-12-31";
        source = createTemporaryObject(transportFactory, testCase);
        store = createTemporaryObject(storeFactory, testCase, {transport: source});
        // Control only this fixture's clock; never change the machine clock.
        // Older implementations still reach the behavioral rollover assertion.
        if (store.dayClock) {
            store.dayClock.stop();
            store.dayClock.localDay = function() { return testCase.sampledDay; };
            store.dayClock.day = sampledDay;
            store.dayClock.interval = 10;
        }
        tryVerify(() => store.loaded && !store.busy && !store.historyLoading);
        compare(store.today, sampledDay);
        source.reads = 0;
    }
    function startClock() {
        if (store.dayClock) store.dayClock.start();
    }
    function test_idle_rollover_data() {
        return [
            {tag: "year boundary", before: "2030-12-31", after: "2031-01-01", label: "Yesterday"},
            {tag: "leap day", before: "2032-02-28", after: "2032-02-29", label: "Yesterday"},
            {tag: "wake after several days", before: "2030-12-31", after: "2031-01-04", label: "Tue, 31 Dec 2030"},
            {tag: "clock moves backward", before: "2030-12-31", after: "2030-12-30", label: "Tomorrow"}
        ];
    }
    function test_idle_rollover(data) {
        sampledDay = data.before;
        source.snapshotDay = data.before;
        if (store.dayClock) store.dayClock.day = data.before;
        store.reload();
        tryVerify(() => !store.busy && store.today === data.before);
        const selected = store.date;
        store.editNote(selected, "SYNTHETIC unsaved diary draft");
        store.noteTimer.stop();
        compare(Display.day(data.before, store.today), "Today");
        source.snapshotDay = data.after;
        sampledDay = data.after;
        startClock();
        tryCompare(store, "today", data.after, 1500);
        compare(Display.day(data.before, store.today), data.label);
        tryVerify(() => !store.busy && store.records.today === data.after);
        compare(store.date, selected);
        compare(store.noteFor(selected), "SYNTHETIC unsaved diary draft");
        verify(store.dirtyNotes[selected]);
    }
    function test_stale_reply_does_not_reverse_live_date() {
        source.hold = true;
        store.reload();
        tryCompare(source, "reads", 1);
        sampledDay = "2031-01-01";
        startClock();
        tryCompare(store, "today", sampledDay);
        wait(160);
        compare(source.reads, 1); // No competing request while the old read is busy.
        source.hold = false;
        source.reply(source.held[0]);
        compare(store.today, sampledDay);
        source.snapshotDay = sampledDay;
        tryVerify(() => !store.busy && store.records.today === sampledDay);
        compare(store.today, sampledDay);
    }
    function test_refresh_failure_keeps_live_labels_and_draft() {
        const selected = store.date;
        store.editNote(selected, "SYNTHETIC retained draft");
        store.noteTimer.stop();
        source.fail = true;
        sampledDay = "2031-01-01";
        startClock();
        tryCompare(store, "today", sampledDay);
        tryVerify(() => store.lastError === "SYNTHETIC read failure" && !store.busy);
        compare(Display.day("2030-12-31", store.today), "Yesterday");
        compare(store.date, selected);
        compare(store.noteFor(selected), "SYNTHETIC retained draft");
        verify(store.dirtyNotes[selected]);
        const reads = source.reads;
        wait(200);
        compare(source.reads, reads); // No idle helper/retry loop.
    }
    function test_unchanged_day_does_not_poll_helper() {
        startClock();
        wait(200);
        compare(source.reads, 0);
    }
}
