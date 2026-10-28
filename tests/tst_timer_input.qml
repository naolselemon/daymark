pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "TimerDurationInput"
    width: 700
    height: 900
    when: windowShown

    Daymark.Theme {
        id: fixtureTheme
        source: ({background: "#181818", foreground: "#eeeeee", accent: "#aaccaa", urgent: "#ffaaaa",
            radius: 8, family: "sans-serif", scale: 1,
            font: {title: 14, body: 12, heading: 18, display: 22, "display-large": 28},
            spacing: {"control-gap": 8, "panel-padding": 16, "control-padding-y": 8, "control-padding-x": 12, "control-height": 44},
            states: {normal: {fill: "#222222", border: "#777777", width: 1},
                "hover-cursor": {fill: "#333333", border: "#999999", width: 1},
                pressed: {fill: "#333333", border: "#999999", width: 1},
                selected: {fill: "#222222", border: "#555555", width: 1},
                selection: {fill: "#446644", border: "#aaccaa", width: 0},
                focus: {fill: "#333333", border: "#aaccaa", width: 1}}})
    }
    Component {
        id: viewFactory
        Daymark.TimerView {
            theme: fixtureTheme
            width: 580
            height: 760
            controller: ({status: "idle", loaded: true, busy: false, error: "",
                recovery: "", muted: true, remainingSeconds: 0, durationSeconds: 0, soundUnavailable: "",
                activityId: "", taskId: "", activityTitle: "", taskTitle: "", targetError: "",
                selectedActivityId: "", selectedTaskId: "", logPending: false, logSaved: false})
        }
    }
    function test_hour_preset_normalizes_without_accepting_invalid_minutes() {
        const view = createTemporaryObject(viewFactory, testCase);
        const start = findChild(view, "countdownPrimary");
        view.digits = "6000";
        verify(!view.validDuration);
        verify(!start.enabled);

        view.preset(60);
        compare(view.field(0), "01");
        compare(view.field(1), "00");
        compare(view.field(2), "00");
        compare(view.inputSeconds, 3600);
        verify(view.validDuration);
        verify(start.enabled);
    }
    function test_finished_link_cannot_be_discarded_by_duration_input_or_enter() {
        const view = createTemporaryObject(viewFactory, testCase);
        let resets = 0;
        let starts = 0;
        view.controller = Object.assign({}, view.controller, {
            status: "finished", activityId: "synthetic-activity", taskId: "synthetic-task",
            activityTitle: "Synthetic learning", taskTitle: "Ownership", durationSeconds: 60,
            reset: function() { resets++; }, start: function() { starts++; }
        });
        view.digits = "100";
        verify(!view.editing);
        verify(!findChild(view, "countdownPrimary").enabled);
        verify(!findChild(view, "countdownTarget").enabled);
        view.append("5");
        view.preset(30);
        view.primaryAction();
        compare(view.digits, "100");
        compare(resets, 0);
        compare(starts, 0);
        verify(findChild(view, "countdownLog").enabled);
        view.reset();
        compare(resets, 1);
    }
    function test_pending_entry_disables_reset_but_keeps_retry_visible() {
        const view = createTemporaryObject(viewFactory, testCase);
        let resets = 0;
        view.controller = Object.assign({}, view.controller, {
            status: "finished", activityId: "synthetic-activity", activityTitle: "Synthetic learning",
            logPending: true, targetError: "Synthetic unavailable target", reset: function() { resets++; }
        });
        verify(!findChild(view, "countdownReset").enabled);
        verify(!findChild(view, "countdownDismiss").enabled);
        verify(findChild(view, "countdownLog").enabled);
        view.reset();
        compare(resets, 0);
    }
    Component {
        id: pickerFactory
        Daymark.CountdownTargetPicker { theme: fixtureTheme }
    }
    Component {
        id: targetStoreFactory
        QtObject {
            property var activities: [
                {id: "synthetic-learning", title: "Learning Rust", tasks: [
                    {id: "synthetic-ownership", title: "Ownership exercises"}]},
                {id: "synthetic-reading", title: "Read a book", tasks: []}
            ]
            function activity(id) { return activities.find(item => item.id === id) || null; }
        }
    }
    function test_picker_search_whole_activity_and_unavailable_selection() {
        const store = createTemporaryObject(targetStoreFactory, testCase);
        const picker = createTemporaryObject(pickerFactory, testCase, {store: store});
        let selections = [];
        picker.chosen.connect(function(activityId, taskId) { selections.push([activityId, taskId]); });
        picker.begin("synthetic-learning", "synthetic-ownership");
        verify(picker.validTarget);
        findChild(picker, "countdownTargetSearch").text = "ownership";
        compare(picker.matches.length, 1);
        compare(picker.matches[0].id, "synthetic-learning");
        picker.taskId = "removed-task";
        verify(!picker.validTarget);
        picker.acceptTarget();
        compare(selections.length, 0);
        picker.taskId = "";
        picker.acceptTarget();
        compare(selections[0][0], "synthetic-learning");
        compare(selections[0][1], "");
        picker.begin("", "");
        verify(picker.validTarget);
        picker.acceptTarget();
        compare(selections[1][0], "");
        compare(selections[1][1], "");
    }
}
