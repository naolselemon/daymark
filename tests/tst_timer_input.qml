pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "TimerDurationInput"
    width: 1100
    height: 1000
    when: windowShown
    visible: true

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
    Component {
        id: controllerFactory
        QtObject {
            property string status: "idle"
            property bool loaded: true
            property bool busy: false
            property string error: ""
            property string recovery: ""
            property bool muted: true
            property int remainingSeconds: 0
            property int durationSeconds: 0
            property string soundUnavailable: ""
            property string activityId: ""
            property string taskId: ""
            property string activityTitle: ""
            property string taskTitle: ""
            property string targetError: ""
            property string selectedActivityId: ""
            property string selectedTaskId: ""
            property bool logPending: false
            property bool logSaved: false
            property var starts: []
            property int resets: 0
            property int pauses: 0
            property int resumes: 0
            property bool deferReset: false
            function start(seconds) {
                starts.push(seconds);
                durationSeconds = seconds;
                remainingSeconds = seconds;
                status = "running";
            }
            function pause() { pauses++; status = "paused"; }
            function resume() { resumes++; status = "running"; }
            function reset() {
                resets++;
                if (deferReset) busy = true;
                else finishReset();
            }
            function finishReset() {
                status = "idle";
                durationSeconds = 0;
                remainingSeconds = 0;
                activityId = "";
                taskId = "";
                busy = false;
            }
        }
    }
    Component {
        id: clipboardFactory
        TextInput { width: 120; height: 30; x: 20; y: 940 }
    }
    function editableView(properties) {
        const controller = createTemporaryObject(controllerFactory, testCase);
        verify(controller);
        const view = createTemporaryObject(viewFactory, testCase, Object.assign({
            controller: controller, width: 1040, height: 900, shortcutsEnabled: true,
            durationExpanded: true
        }, properties || {}));
        verify(view);
        verify(waitForRendering(view));
        return view;
    }
    function clickUnit(view, name) {
        const field = findChild(view, name);
        verify(field, name);
        tryVerify(() => field.width > 0 && field.height > 0);
        mouseClick(field);
        tryCompare(field, "activeFocus", true);
        return field;
    }
    function typeDigits(value) {
        for (let i = 0; i < value.length; i++) keyClick(Qt.Key_0 + Number(value[i]));
    }
    function pasteText(field, value) {
        const source = createTemporaryObject(clipboardFactory, testCase, {text: value});
        source.selectAll();
        source.copy();
        field.forceActiveFocus();
        keyClick(Qt.Key_A, Qt.ControlModifier);
        keyClick(Qt.Key_V, Qt.ControlModifier);
    }
    function test_native_unit_editing_and_tab_order_data() {
        return [
            {tag: "circle", prefix: "countdown", other: "countdownDuration"},
            {tag: "duration", prefix: "countdownDuration", other: "countdown"}
        ];
    }
    function test_native_unit_editing_and_tab_order(data) {
        const view = editableView();
        const hours = clickUnit(view, data.prefix + "Hours");
        tryCompare(hours, "selectedText", "00");
        typeDigits("1");
        compare(hours.text, "1");
        compare(hours.cursorPosition, 1);
        compare(view.digits, "10000");
        compare(findChild(view, data.other + "Hours").text, "01");
        typeDigits("2");
        compare(hours.text, "12");
        compare(view.inputSeconds, 12 * 3600);

        keyClick(Qt.Key_Tab);
        const minutes = findChild(view, data.prefix + "Minutes");
        tryCompare(minutes, "activeFocus", true);
        tryCompare(minutes, "selectedText", "00");
        typeDigits("3");
        compare(minutes.text, "3");
        compare(findChild(view, data.other + "Minutes").text, "03");
        compare(view.digits, "120300");
        keyClick(Qt.Key_Tab);
        const seconds = findChild(view, data.prefix + "Seconds");
        tryCompare(seconds, "activeFocus", true);
        tryCompare(seconds, "selectedText", "00");
        typeDigits("4");
        compare(seconds.text, "4");
        compare(findChild(view, data.other + "Seconds").text, "04");
        compare(view.digits, "120304");
        keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        tryCompare(minutes, "activeFocus", true);
        tryCompare(minutes, "selectedText", "3");
        keyClick(Qt.Key_Return);
        compare(view.controller.starts.length, 1);
        compare(view.controller.starts[0], 12 * 3600 + 3 * 60 + 4);
        compare(view.controller.pauses, 0);
        verify(hours.readOnly && minutes.readOnly && seconds.readOnly);
    }
    function test_invalid_ranges_stay_visible_and_cannot_start_data() {
        return [
            {tag: "circle-minutes", name: "countdownMinutes", other: "countdownDurationMinutes", digits: "6000"},
            {tag: "circle-seconds", name: "countdownSeconds", other: "countdownDurationSeconds", digits: "60"},
            {tag: "duration-minutes", name: "countdownDurationMinutes", other: "countdownMinutes", digits: "6000"},
            {tag: "duration-seconds", name: "countdownDurationSeconds", other: "countdownSeconds", digits: "60"}
        ];
    }
    function test_invalid_ranges_stay_visible_and_cannot_start(data) {
        const view = editableView();
        const field = clickUnit(view, data.name);
        tryCompare(field, "selectedText", "00");
        typeDigits("60");
        compare(field.text, "60");
        compare(findChild(view, data.other).text, "60");
        compare(view.digits, data.digits);
        verify(!view.validDuration);
        verify(!findChild(view, "countdownPrimary").enabled);
        keyClick(Qt.Key_Return);
        compare(view.controller.starts.length, 0);

        keyClick(Qt.Key_A, Qt.ControlModifier);
        typeDigits("59");
        compare(field.text, "59");
        verify(view.validDuration);
        for (const rejected of ["100", "-1", "1a", "1:20", " 5"]) {
            pasteText(field, rejected);
            compare(field.text, "59", "Reject the entire paste: " + rejected);
        }
        pasteText(field, "99");
        compare(field.text, "99");
        verify(!view.validDuration);
        keyClick(Qt.Key_Return);
        compare(view.controller.starts.length, 0);
        keyClick(Qt.Key_A, Qt.ControlModifier);
        keyClick(Qt.Key_Backspace);
        compare(field.text, "");
        compare(view.digits, "");
        verify(!view.validDuration);
        keyClick(Qt.Key_Return);
        compare(view.controller.starts.length, 0);
    }
    function test_maximum_hours_and_whole_paste_rejection() {
        const view = editableView();
        const hours = clickUnit(view, "countdownHours");
        tryCompare(hours, "selectedText", "00");
        pasteText(hours, "99");
        compare(view.digits, "990000");
        pasteText(hours, "100");
        compare(hours.text, "99");
        compare(view.digits, "990000");
        pasteText(findChild(view, "countdownDurationMinutes"), "59");
        pasteText(findChild(view, "countdownSeconds"), "59");
        compare(view.inputSeconds, 99 * 3600 + 59 * 60 + 59);
        verify(view.validDuration);
        keyClick(Qt.Key_Enter);
        compare(view.controller.starts.length, 1);
        compare(view.controller.starts[0], 359999);
    }
    function test_native_editing_keys_do_not_invoke_digit_shortcuts() {
        const view = editableView();
        view.preset(15);
        const minutes = clickUnit(view, "countdownMinutes");
        tryCompare(minutes, "selectedText", "15");
        typeDigits("45");
        compare(minutes.text, "45");
        compare(view.digits, "4500");
        keyClick(Qt.Key_Home);
        keyClick(Qt.Key_Delete);
        compare(minutes.text, "5");
        compare(view.digits, "500");
        keyClick(Qt.Key_End);
        keyClick(Qt.Key_Backspace);
        compare(minutes.text, "");
        compare(view.digits, "");
        typeDigits("12");
        keyClick(Qt.Key_Left, Qt.ShiftModifier);
        keyClick(Qt.Key_3);
        compare(minutes.text, "13");
        compare(view.digits, "1300");
        keyClick(Qt.Key_A, Qt.ControlModifier);
        keyClick(Qt.Key_X, Qt.ControlModifier);
        compare(minutes.text, "");
        compare(view.digits, "");
        keyClick(Qt.Key_V, Qt.ControlModifier);
        compare(minutes.text, "13");
        compare(view.digits, "1300");
        keyClick(Qt.Key_Return);
        compare(view.controller.starts.length, 1);
        compare(view.controller.starts[0], 13 * 60);
        compare(view.controller.pauses, 0);
    }
    function test_unrelated_text_input_owns_digits_backspace_and_return() {
        const view = editableView();
        view.preset(5);
        const other = createTemporaryObject(clipboardFactory, testCase);
        mouseClick(other);
        tryCompare(other, "activeFocus", true);
        typeDigits("12");
        compare(other.text, "12");
        compare(view.digits, "500");
        keyClick(Qt.Key_Backspace);
        compare(other.text, "1");
        compare(view.digits, "500");
        keyClick(Qt.Key_Return);
        compare(view.controller.starts.length, 0);
    }
    function test_presets_and_keypad_synchronize_after_native_editing() {
        const view = editableView();
        const hours = clickUnit(view, "countdownHours");
        tryCompare(hours, "selectedText", "00");
        typeDigits("2");
        compare(view.digits, "20000");
        mouseClick(findChild(view, "countdownPreset60"));
        compare(view.digits, "10000");
        compare(hours.text, "01");
        compare(findChild(view, "countdownDurationHours").text, "01");
        mouseClick(findChild(view, "countdownReset"));
        compare(view.digits, "");
        for (const digit of ["1", "2", "3"]) mouseClick(findChild(view, "countdownKey" + digit));
        compare(view.digits, "123");
        compare(findChild(view, "countdownMinutes").text, "01");
        compare(findChild(view, "countdownDurationSeconds").text, "23");
        mouseClick(findChild(view, "countdownKeyback"));
        compare(view.digits, "12");
        compare(findChild(view, "countdownMinutes").text, "00");
        compare(findChild(view, "countdownDurationSeconds").text, "12");
        // With a button focused, keyboard entry still uses the keypad's shift semantics.
        keyClick(Qt.Key_4);
        compare(view.digits, "124");
        keyClick(Qt.Key_Backspace);
        compare(view.digits, "12");
        mouseClick(findChild(view, "countdownKey00"));
        compare(view.digits, "1200");
        compare(findChild(view, "countdownDurationMinutes").text, "12");
        compare(findChild(view, "countdownSeconds").text, "00");
    }
    function test_drafts_survive_fold_reflow_navigation_and_target_selection() {
        const view = editableView();
        const minutes = clickUnit(view, "countdownDurationMinutes");
        tryCompare(minutes, "selectedText", "00");
        typeDigits("7");
        compare(minutes.text, "7");
        mouseClick(findChild(view, "countdownDurationToggle"));
        verify(!view.durationExpanded);
        compare(view.digits, "700");
        view.width = 500;
        view.visible = false;
        view.controller.selectedActivityId = "synthetic-learning";
        view.controller.selectedTaskId = "synthetic-ownership";
        view.visible = true;
        view.width = 1040;
        verify(waitForRendering(view));
        mouseClick(findChild(view, "countdownDurationToggle"));
        verify(view.durationExpanded);
        compare(minutes.text, "7");
        compare(findChild(view, "countdownMinutes").text, "07");
        compare(view.digits, "700");
        pasteText(minutes, "8");
        compare(view.digits, "800");
        compare(findChild(view, "countdownMinutes").text, "08");
    }
    function test_focused_input_is_protected_during_state_changes_data() {
        return [
            {tag: "running", changes: {status: "running", durationSeconds: 300, remainingSeconds: 287}},
            {tag: "paused", changes: {status: "paused", durationSeconds: 300, remainingSeconds: 287}},
            {tag: "linked-finished", changes: {status: "finished", activityId: "synthetic-activity", durationSeconds: 300}},
            {tag: "pending-idle", changes: {logPending: true}},
            {tag: "pending-finished", changes: {status: "finished", logPending: true}},
            {tag: "busy", changes: {busy: true}},
            {tag: "loading", changes: {loaded: false}},
            {tag: "error", changes: {error: "Synthetic persistence error"}}
        ];
    }
    function test_focused_input_is_protected_during_state_changes(data) {
        const view = editableView();
        const seconds = clickUnit(view, "countdownSeconds");
        tryCompare(seconds, "selectedText", "00");
        typeDigits("5");
        compare(view.digits, "5");
        for (const name in data.changes) view.controller[name] = data.changes[name];
        verify(seconds.readOnly);
        verify(findChild(view, "countdownDurationSeconds").readOnly);
        verify(seconds.activeFocus);
        keyClick(Qt.Key_9);
        keyClick(Qt.Key_Backspace);
        keyClick(Qt.Key_Return);
        view.editUnit(2, "9", false);
        view.append("9");
        view.erase();
        view.preset(30);
        compare(view.digits, "5");
        compare(view.controller.resets, 0);
        compare(view.controller.starts.length, 0);
        compare(view.controller.pauses, 0);
        compare(view.controller.resumes, 0);
        if (data.tag === "running" || data.tag === "paused") {
            compare(seconds.text, "47");
            compare(findChild(view, "countdownDurationMinutes").text, "05");
            compare(findChild(view, "countdownDurationSeconds").text, "00");
        }
        view.controller.status = "idle";
        view.controller.activityId = "";
        view.controller.logPending = false;
        view.controller.loaded = true;
        view.controller.busy = false;
        view.controller.error = "";
        clickUnit(view, "countdownHours");
        const restored = clickUnit(view, "countdownSeconds");
        tryCompare(restored, "selectedText", restored.text);
        typeDigits("8");
        compare(view.digits, "8");
        compare(findChild(view, "countdownDurationSeconds").text, "08");
    }
    function test_transient_busy_preserves_focused_draft_and_cursor() {
        const view = editableView();
        const minutes = clickUnit(view, "countdownMinutes");
        tryCompare(minutes, "selectedText", "00");
        typeDigits("1");
        compare(minutes.text, "1");
        compare(minutes.cursorPosition, 1);
        view.controller.busy = true;
        keyClick(Qt.Key_9);
        keyClick(Qt.Key_Return);
        compare(minutes.text, "1");
        compare(view.digits, "100");
        compare(view.controller.starts.length, 0);
        view.controller.busy = false;
        verify(minutes.activeFocus);
        compare(minutes.cursorPosition, 1);
        typeDigits("2");
        compare(minutes.text, "12");
        compare(view.digits, "1200");
        compare(findChild(view, "countdownDurationMinutes").text, "12");
    }
    function test_standalone_finished_restart_and_asynchronous_edit_reset() {
        const view = editableView();
        view.preset(5);
        view.controller.status = "finished";
        view.controller.durationSeconds = 300;
        compare(findChild(view, "countdownSeconds").text, "00");
        compare(findChild(view, "countdownDurationMinutes").text, "05");
        mouseClick(findChild(view, "countdownPrimary"));
        compare(view.controller.starts.length, 1);
        compare(view.controller.starts[0], 300);

        view.controller.status = "finished";
        view.controller.remainingSeconds = 0;
        view.controller.deferReset = true;
        const seconds = clickUnit(view, "countdownSeconds");
        tryCompare(seconds, "selectedText", "00");
        // Both keystrokes must survive the reset started by the leading zero.
        typeDigits("09");
        compare(view.digits, "9");
        compare(view.controller.resets, 1);
        verify(!seconds.readOnly);
        verify(!findChild(view, "countdownPrimary").enabled);
        compare(findChild(view, "countdownDurationSeconds").text, "09");
        keyClick(Qt.Key_Return);
        compare(view.digits, "9");
        compare(view.controller.starts.length, 1);
        view.controller.finishReset();
        compare(findChild(view, "countdownMinutes").text, "00");
        compare(findChild(view, "countdownDurationSeconds").text, "09");
        mouseClick(findChild(view, "countdownPrimary"));
        compare(view.controller.starts.length, 2);
        compare(view.controller.starts[1], 9);

        view.controller.status = "finished";
        view.controller.remainingSeconds = 0;
        const minutes = clickUnit(view, "countdownDurationMinutes");
        tryCompare(minutes, "selectedText", "00");
        typeDigits("2");
        compare(view.digits, "209");
        compare(view.controller.resets, 2);
        compare(findChild(view, "countdownMinutes").text, "02");
        compare(findChild(view, "countdownSeconds").text, "09");
        view.controller.finishReset();
        compare(findChild(view, "countdownMinutes").text, "02");
        compare(findChild(view, "countdownSeconds").text, "09");
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
