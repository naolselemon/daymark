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
                focus: {fill: "#333333", border: "#aaccaa", width: 1}}})
    }
    Component {
        id: viewFactory
        Daymark.TimerView {
            theme: fixtureTheme
            width: 580
            height: 760
            controller: ({status: "idle", loaded: true, busy: false, error: "",
                recovery: "", muted: true, remainingSeconds: 0, durationSeconds: 0, soundUnavailable: ""})
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
}
