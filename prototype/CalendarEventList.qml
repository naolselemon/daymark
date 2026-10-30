pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var theme
    required property var events
    property string filterDate: ""
    property string windowStart: ""
    property string windowEnd: ""
    property string windowLabel: ""
    property string calendarName: ""
    property string statusText: ""
    property bool embedded: false
    property var excludedDates: []
    readonly property bool contentsVisible: embedded || expanded
    readonly property var groups: groupEvents()
    property int page: 0
    property bool expanded: false
    readonly property int entryCount: groups.reduce((total, group) => total + group.events.length, 0)
    readonly property int pageCount: Math.max(1, Math.ceil(entryCount / 50))
    readonly property var visibleGroups: pageGroups()
    onGroupsChanged: page = 0
    objectName: "calendarEventList"
    spacing: theme.space(6)

    function dateLabel(day) { return Qt.formatDate(new Date(day + "T12:00:00"), "ddd, d MMM"); }
    function nextDay(day) {
        const date = new Date(day + "T12:00:00");
        date.setDate(date.getDate() + 1);
        return Qt.formatDate(date, "yyyy-MM-dd");
    }
    function groupEvents() {
        const grouped = {};
        for (const event of events) {
            if (filterDate) {
                if (excludedDates.indexOf(filterDate) < 0 && event.startDate <= filterDate && event.endDate >= filterDate) {
                    if (!grouped[filterDate]) grouped[filterDate] = [];
                    grouped[filterDate].push(event);
                }
                continue;
            }
            let day = windowStart && windowStart > event.startDate ? windowStart : event.startDate;
            const end = windowEnd && windowEnd < event.endDate ? windowEnd : event.endDate;
            while (day <= end) {
                if (excludedDates.indexOf(day) < 0) {
                    if (!grouped[day]) grouped[day] = [];
                    grouped[day].push(event);
                }
                day = nextDay(day);
            }
        }
        return Object.keys(grouped).sort().map(day => ({date: day, events: grouped[day].sort((a, b) => {
            if (a.allDay !== b.allDay) return a.allDay ? -1 : 1;
            const first = a.startDate + a.startTime;
            const second = b.startDate + b.startTime;
            return first < second ? -1 : first > second ? 1 : a.title.localeCompare(b.title);
        })}));
    }
    function pageGroups() {
        let skip = page * 50;
        let remaining = 50;
        const result = [];
        for (const group of groups) {
            if (skip >= group.events.length) { skip -= group.events.length; continue; }
            const selected = group.events.slice(skip, skip + remaining);
            result.push({date: group.date, events: selected});
            remaining -= selected.length;
            skip = 0;
            if (!remaining) break;
        }
        return result;
    }

    Rectangle { visible: !root.embedded; Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
    DisclosureHeading {
        visible: !root.embedded
        theme: root.theme; title: qsTr("Calendar"); Layout.fillWidth: true
        objectName: "calendarEventsToggle"
        summary: !root.filterDate ? (root.excludedDates.length ? qsTr("Other dates") : qsTr("Upcoming events"))
            : root.entryCount === 1 ? qsTr("1 event") : qsTr("%1 events").arg(root.entryCount)
        expanded: root.expanded
        onClicked: root.expanded = !root.expanded
    }
    DText {
        theme: root.theme; Layout.fillWidth: true; visible: !root.embedded && root.contentsVisible
        text: (root.calendarName || qsTr("Google Calendar")) + " · " + qsTr("Read only")
        color: root.theme.secondary; font.pixelSize: root.theme.small
    }
    DText {
        theme: root.theme; text: root.statusText; color: root.theme.secondary
        Layout.fillWidth: true; font.pixelSize: root.theme.small; visible: !root.embedded && root.contentsVisible && text !== ""
    }
    DText {
        theme: root.theme; text: root.windowLabel; color: root.theme.secondary
        Layout.fillWidth: true; font.pixelSize: root.theme.small; visible: !root.embedded && root.contentsVisible && text !== ""
        objectName: "calendarEventWindow"
    }
    Repeater {
        model: root.contentsVisible ? root.visibleGroups : []
        ColumnLayout {
            id: dayGroup
            required property var modelData
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: root.theme.space(2)
            objectName: "calendarDay-" + modelData.date
            DText {
                theme: root.theme; text: root.dateLabel(dayGroup.modelData.date)
                font.bold: true; color: root.theme.secondary; Layout.fillWidth: true
                visible: root.filterDate === ""
            }
            Repeater {
                model: dayGroup.modelData.events
                CalendarEventRow {
                    required property var modelData
                    theme: root.theme; event: modelData; day: dayGroup.modelData.date
                    calendarName: root.calendarName
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                }
            }
        }
    }
    DText {
        theme: root.theme; color: root.theme.secondary; Layout.fillWidth: true
        visible: !root.embedded && root.contentsVisible && root.groups.length === 0
        text: root.filterDate ? qsTr("No calendar events for this day.") : qsTr("No calendar events in this window.")
    }
    RowLayout {
        visible: root.contentsVisible && root.pageCount > 1; Layout.fillWidth: true
        Item { Layout.fillWidth: true }
        DButton {
            theme: root.theme; text: qsTr("Previous calendar events"); iconName: "previous"
            enabled: root.page > 0; objectName: "calendarEventsPrevious"
            onClicked: root.page--
        }
        DText {
            theme: root.theme; text: (root.page + 1) + " / " + root.pageCount
            color: root.theme.secondary; Accessible.name: qsTr("Calendar page %1 of %2").arg(root.page + 1).arg(root.pageCount)
        }
        DButton {
            theme: root.theme; text: qsTr("Next calendar events"); iconName: "next"
            enabled: root.page + 1 < root.pageCount; objectName: "calendarEventsNext"
            onClicked: root.page++
        }
    }
}
