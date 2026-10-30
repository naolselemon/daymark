pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "CalendarAgenda"
    width: 700; height: 900
    visible: true; when: windowShown
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
    Component {
        id: listFactory
        Daymark.CalendarEventList { theme: fixtureTheme; width: 580; events: [] }
    }
    function event(id, start, end) {
        return {id: id, title: "Synthetic " + id, startDate: start, endDate: end,
            allDay: true, startTime: "", endTime: "", endTimeDate: end};
    }
    function test_inline_dates_leave_later_portion_of_multiday_event_in_calendar() {
        const list = createTemporaryObject(listFactory, testCase, {
            events: [event("span", "2026-12-31", "2027-01-02"), event("later", "2027-01-03", "2027-01-03")],
            excludedDates: ["2026-12-31", "2027-01-01"], expanded: true
        });
        verify(list);
        compare(list.groups.map(group => group.date), ["2027-01-02", "2027-01-03"]);
        compare(list.groups[0].events[0].id, "span");
        list.excludedDates = ["2027-01-01", "2027-01-02"];
        compare(list.groups.map(group => group.date), ["2026-12-31", "2027-01-03"]);
    }
    function test_selected_day_displays_only_overlapping_events_without_expansion() {
        const list = createTemporaryObject(listFactory, testCase, {
            events: [event("previous", "2028-02-28", "2028-02-28"),
                event("span", "2028-02-28", "2028-03-01"), event("next", "2028-03-01", "2028-03-01")],
            filterDate: "2028-02-29", embedded: true
        });
        verify(list);
        compare(list.entryCount, 1);
        tryVerify(() => findChild(list, "calendarEvent-span") !== null);
        verify(findChild(list, "calendarEvent-previous") === null);
        verify(findChild(list, "calendarEvent-next") === null);
        list.filterDate = "2028-03-01";
        compare(list.entryCount, 2);
        tryVerify(() => findChild(list, "calendarEvent-next") !== null);
    }
    function test_event_pagination_preserves_every_occurrence_and_resets_for_new_day() {
        const events = [];
        for (let i = 0; i < 51; i++) events.push(event("row" + i.toString().padStart(2, "0"), "2026-10-30", "2026-10-30"));
        const list = createTemporaryObject(listFactory, testCase, {
            events: events, filterDate: "2026-10-30", embedded: true
        });
        verify(list);
        compare(list.visibleGroups[0].events.map(row => row.id), events.slice(0, 50).map(row => row.id));
        list.page = 1;
        compare(list.visibleGroups[0].events.map(row => row.id), ["row50"]);
        list.filterDate = "2026-10-31";
        compare(list.page, 0);
        compare(list.visibleGroups.length, 0);
    }
}
