pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    objectName: "entryCalendar"
    required property var theme
    required property var days
    required property var counts
    readonly property int dayCount: days ? days.length : 0
    readonly property real gap: theme.space(4)
    readonly property real inset: theme.space(4)
    readonly property real maximum: {
        let result = 0;
        for (let i = 0; i < dayCount; ++i)
            result = Math.max(result, counts && i < counts.length ? counts[i] : 0);
        return result;
    }
    // Measure independently of allocated width so reflow cannot change its own threshold.
    readonly property real minimumTileWidth: {
        let result = smallMetrics.advanceWidth("31");
        for (let i = 0; i < dayCount; ++i) {
            result = Math.max(result, countMetrics.advanceWidth(String(counts && i < counts.length ? counts[i] : 0)));
            if (i < 7)
                result = Math.max(result, smallMetrics.advanceWidth(Qt.formatDate(new Date(days[i].date + "T12:00:00"), "ddd")));
        }
        return Math.ceil(result) + inset * 2;
    }
    readonly property int columns: Math.max(1, Math.min(7, dayCount, Math.floor((width + gap) / (minimumTileWidth + gap))))
    readonly property bool weekdayColumns: columns === 7
    spacing: theme.space(12)

    FontMetrics {
        id: smallMetrics
        font.family: root.theme.family
        font.pixelSize: root.theme.small
    }
    FontMetrics {
        id: countMetrics
        font.family: root.theme.family
        font.pixelSize: root.theme.heading
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: root.theme.space(6)
        SectionHeading {
            theme: root.theme
            text: "Daily entries"
            Layout.fillWidth: true
            Layout.minimumWidth: 0
        }
        DText {
            objectName: "entryCalendarRange"
            theme: root.theme
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            visible: root.dayCount > 0
            text: root.dayCount > 0 ? Display.span(root.days[0].date, root.days[root.dayCount - 1].date) : ""
            color: root.theme.secondary
            font.pixelSize: root.theme.small
            wrapMode: Text.Wrap
        }
    }

    GridLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.preferredWidth: 0
        columns: root.columns
        columnSpacing: root.gap
        rowSpacing: root.gap

        Repeater {
            model: root.weekdayColumns ? 7 : 0
            delegate: DText {
                required property int index
                theme: root.theme
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                Layout.bottomMargin: root.theme.space(4)
                // A rolling fortnight may start on any weekday, not necessarily Monday.
                text: Qt.formatDate(new Date(root.days[index].date + "T12:00:00"), "ddd")
                color: root.theme.secondary
                font.pixelSize: root.theme.small
                horizontalAlignment: Text.AlignHCenter
                Accessible.ignored: true
            }
        }
        Repeater {
            model: root.dayCount
            delegate: Rectangle {
                id: tile
                required property int index
                readonly property string date: root.days[index].date
                readonly property real entries: root.counts && index < root.counts.length ? root.counts[index] : 0
                readonly property bool currentDay: index === root.dayCount - 1
                readonly property date calendarDate: new Date(date + "T12:00:00")
                objectName: "entryDay-" + date
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                implicitHeight: Math.max(root.theme.space(72), tileContent.implicitHeight + root.theme.space(12))
                radius: root.theme.radius
                color: entries > 0 && root.maximum > 0
                    ? Qt.tint(root.theme.surface, Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b,
                        0.06 + 0.14 * entries / root.maximum))
                    : root.theme.surface
                border.color: currentDay ? root.theme.accent : Qt.rgba(root.theme.border.r, root.theme.border.g, root.theme.border.b, root.theme.border.a * 0.4)
                border.width: root.theme.space(1)
                Accessible.role: Accessible.StaticText
                Accessible.name: Display.day(date) + ": " + entries + (entries === 1 ? " entry" : " entries") + (currentDay ? ", today" : "")

                ColumnLayout {
                    id: tileContent
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: root.theme.space(6)
                    anchors.leftMargin: root.inset
                    anchors.rightMargin: root.inset
                    spacing: root.theme.space(2)
                    DText {
                        theme: root.theme
                        visible: !root.weekdayColumns
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: Qt.formatDate(tile.calendarDate, "ddd")
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                        wrapMode: Text.NoWrap
                        Accessible.ignored: true
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: Qt.formatDate(tile.calendarDate, "d")
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                        wrapMode: Text.NoWrap
                        Accessible.ignored: true
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: String(tile.entries)
                        color: tile.entries > 0 ? root.theme.foreground : root.theme.secondary
                        font.pixelSize: root.theme.heading
                        horizontalAlignment: Text.AlignHCenter
                        // Only the one-column last resort wraps; counts are never elided or scaled down.
                        wrapMode: Text.WrapAnywhere
                        Accessible.ignored: true
                    }
                    DText {
                        theme: root.theme
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        Layout.minimumHeight: smallMetrics.height
                        // The dated legend still identifies today when its name cannot fit inside a narrow tile.
                        text: tile.currentDay && tile.width - root.inset * 2 >= smallMetrics.advanceWidth("Today") ? "Today" : ""
                        color: root.theme.accent
                        font.pixelSize: root.theme.small
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WrapAnywhere
                        Accessible.ignored: true
                    }
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: root.theme.space(12)
        DText {
            theme: root.theme
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.preferredWidth: 1
            text: "0 = no entries"
            color: root.theme.secondary
            font.pixelSize: root.theme.small
            wrapMode: Text.Wrap
        }
        DText {
            theme: root.theme
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.preferredWidth: 1
            visible: root.dayCount > 0
            text: root.dayCount > 0 ? "Today · " + Qt.formatDate(new Date(root.days[root.dayCount - 1].date + "T12:00:00"), "d MMM") : ""
            color: root.theme.secondary
            font.pixelSize: root.theme.small
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
        }
    }
}
