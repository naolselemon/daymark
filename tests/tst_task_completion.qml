pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "ExplicitTaskCompletion"
    width: 1000
    height: 1000
    visible: true
    when: windowShown

    Daymark.Theme {
        id: fixtureTheme
        source: ({background: "#181818", foreground: "#eeeeee", accent: "#aaccaa", urgent: "#ffaaaa",
            radius: 8, family: "sans-serif", scale: 1,
            font: {title: 14, body: 12, heading: 18, display: 22, "display-large": 28},
            spacing: {"control-gap": 8, "panel-padding": 16, "control-padding-y": 8, "control-padding-x": 12,
                "control-height": 44, "input-padding-y": 8},
            states: {normal: {fill: "#222222", border: "#777777", width: 1},
                "hover-cursor": {fill: "#333333", border: "#999999", width: 1},
                pressed: {fill: "#333333", border: "#999999", width: 1},
                selected: {fill: "#222222", border: "#555555", width: 1},
                selection: {fill: "#446644", border: "#aaccaa", width: 0},
                focus: {fill: "#333333", border: "#aaccaa", width: 1}}})
    }
    Component {
        id: sourceFactory
        QtObject {
            property var current: ({id: "activity", title: "Synthetic activity", status: "open", revision: 1,
                plannedFor: "", note: "", pinned: false, completedDate: "",
                tasks: [{id: "task", title: "Synthetic task", done: false}]})
            property bool loaded: true
            property string today: "2026-10-29"
            property var insights: null
            property var pending: null
            property int sequence: 0
            function activity(id) { return id === "activity" ? current : null; }
            function sessionsFor(id) { return []; }
            function validDate(value, optional) { return optional || value !== ""; }
            function newRequestId() { return "draft-" + (++sequence); }
            function updateActivity(id, fields, callback, requestId) { pending = callback; }
        }
    }
    Component {
        id: detailFactory
        Daymark.ActivityDetail { theme: fixtureTheme; width: 900; height: 900 }
    }
    Component { id: spyFactory; SignalSpy {} }
    Component {
        id: rowFactory
        Daymark.SessionRow {
            theme: fixtureTheme
            width: 700
            session: ({id: "entry", note: "Historical prose stays readable", tasks: [{id: "task", title: "Old task title"}]})
        }
    }
    Component {
        id: selectionFactory
        Daymark.TaskSelector {
            theme: fixtureTheme
            width: 700
            tasks: [{id: "task", title: "Reusable completed task", done: true}]
            onSelectionEdited: ids => selectedIds = ids
        }
    }

    function test_task_checkbox_waits_for_acknowledgement_and_reopens() {
        const source = createTemporaryObject(sourceFactory, testCase);
        const detail = createTemporaryObject(detailFactory, testCase, {store: source});
        detail.activityId = "activity";
        const spy = createTemporaryObject(spyFactory, testCase, {target: detail, signalName: "taskCompleteRequested"});
        wait(0);
        let toggle = findChild(detail, "detailTaskDone-task");
        verify(toggle);
        toggle.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(spy.count, 1);
        compare(spy.signalArguments[0][0], "activity");
        compare(spy.signalArguments[0][1], "task");
        verify(!toggle.checked); // Request or failed save alone cannot alter the checkbox.
        source.current = Object.assign({}, source.current, {status: "done", revision: 2,
            completedDate: source.today, tasks: [{id: "task", title: "Synthetic task", done: true}]});
        wait(0);
        toggle = findChild(detail, "detailTaskDone-task");
        verify(toggle.checked);
        toggle.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(spy.count, 2);
        verify(toggle.checked);
        source.current = Object.assign({}, source.current, {status: "open", revision: 3,
            completedDate: "", tasks: [{id: "task", title: "Synthetic task", done: false}]});
        wait(0);
        verify(!findChild(detail, "detailTaskDone-task").checked);
        detail.actionsEnabled = false;
        verify(!findChild(detail, "detailTaskDone-task").enabled);
    }

    function test_failed_activity_draft_survives_completion_snapshot() {
        const source = createTemporaryObject(sourceFactory, testCase);
        const detail = createTemporaryObject(detailFactory, testCase, {store: source});
        detail.activityId = "activity";
        detail.editing = true;
        const title = findChild(detail, "detailTitle");
        title.text = "Unsaved synthetic title";
        verify(detail.dirty);
        detail.save();
        verify(detail.saving);
        source.pending(false, null, {code: "storage", message: "Synthetic save failure"});
        verify(detail.failed);
        const requestId = detail.pendingRequestId;
        source.current = Object.assign({}, source.current, {status: "done", revision: 2,
            completedDate: source.today, tasks: [{id: "task", title: "Synthetic task", done: true}]});
        wait(0);
        compare(title.text, "Unsaved synthetic title");
        compare(detail.pendingRequestId, requestId);
        compare(detail.expectedRevision, 1);
        verify(detail.dirty);
    }

    function test_logged_title_follows_parent_without_striking_historical_prose() {
        const row = createTemporaryObject(rowFactory, testCase, {
            activity: {id: "activity", title: "Current activity title", status: "open"}});
        const title = findChild(row, "sessionTitle-entry");
        const prose = findChild(row, "sessionNote-entry");
        const check = findChild(row, "sessionDone-entry");
        verify(!title.font.strikeout);
        verify(!check.visible);
        row.activity = {id: "activity", title: "Current activity title", status: "done"};
        verify(title.font.strikeout);
        verify(check.visible);
        verify(!prose.font.strikeout);
        compare(prose.text, "Historical prose stays readable");
        row.activity = {id: "activity", title: "Current activity title", status: "open"};
        verify(!title.font.strikeout);
        verify(!check.visible);
    }

    function test_logging_selection_remains_independent_of_task_done() {
        const selector = createTemporaryObject(selectionFactory, testCase);
        const choice = findChild(selector, "taskSelection-task");
        verify(!choice.checked);
        choice.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(selector.selectedIds.length, 1);
        compare(selector.selectedIds[0], "task");
        choice.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(selector.selectedIds.length, 0);
        verify(selector.tasks[0].done);
    }
}
