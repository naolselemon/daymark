pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    objectName: "entryBars"
    required property var theme
    required property var days
    required property var counts
    readonly property int dayCount: days ? days.length : 0
    readonly property real maximum: counts && counts.length ? Math.max(0, ...counts) : 0
    readonly property real countWidth: counts && counts.length
        ? Math.max(...counts.map(count => countMetrics.advanceWidth(String(count)))) : 0
    readonly property real gap: theme.space(6)
    readonly property int columns: dayCount > 7
        && width < dayCount * Math.max(theme.space(40), countWidth) + (dayCount - 1) * gap ? 7 : Math.max(1, dayCount)
    readonly property int rowCount: Math.ceil(dayCount / columns)
    readonly property real columnWidth: (width - gap * (columns - 1)) / columns
    readonly property bool separateCounts: countWidth > columnWidth
    spacing: theme.space(18)

    FontMetrics {
        id: countMetrics
        font.family: root.theme.family
        font.pixelSize: root.theme.small
    }

    Repeater {
        model: root.rowCount
        delegate: ColumnLayout {
            id: weekRow
            required property int index
            readonly property int firstDay: index * root.columns
            readonly property int dayCount: Math.min(root.columns, root.dayCount - firstDay)
            Layout.fillWidth: true
            spacing: root.theme.space(10)

            DText {
                theme: root.theme
                Layout.fillWidth: true
                visible: root.rowCount > 1
                text: Display.span(root.days[weekRow.firstDay].date, root.days[weekRow.firstDay + weekRow.dayCount - 1].date)
                color: root.theme.secondary
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
            }
            Item {
                Layout.fillWidth: true
                implicitHeight: (root.separateCounts ? 0 : countMetrics.height + root.theme.space(8))
                    + root.theme.space(80) + countMetrics.height + root.theme.space(8)

                // Both weeks share a scale and each row keeps one baseline,
                // including when large exact counts move into the list below.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    y: parent.height - countMetrics.height - root.theme.space(8) - root.theme.space(40)
                    height: root.theme.space(1)
                    color: root.theme.border
                    opacity: 0.35
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    y: parent.height - countMetrics.height - root.theme.space(8)
                    height: root.theme.space(1)
                    color: root.theme.border
                }
                RowLayout {
                    anchors.fill: parent
                    spacing: root.gap
                    Repeater {
                        model: weekRow.dayCount
                        delegate: ColumnLayout {
                            id: dayColumn
                            required property int index
                            readonly property int dayIndex: weekRow.firstDay + index
                            readonly property string date: root.days[dayIndex].date
                            readonly property real entries: root.counts && dayIndex < root.counts.length ? root.counts[dayIndex] : 0
                            readonly property bool currentDay: dayIndex === root.dayCount - 1
                            objectName: "entryBar-" + date
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.minimumWidth: 0
                            spacing: root.theme.space(8)
                            Accessible.role: Accessible.StaticText
                            Accessible.name: date + ": " + entries + (entries === 1 ? " entry" : " entries") + (currentDay ? ", today" : "")

                            DText {
                                theme: root.theme
                                visible: !root.separateCounts
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                Layout.preferredHeight: countMetrics.height
                                text: String(dayColumn.entries)
                                font.pixelSize: root.theme.small
                                color: dayColumn.entries > 0 ? root.theme.foreground : root.theme.secondary
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.NoWrap
                                Accessible.ignored: true
                            }
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: root.theme.space(80)
                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: Math.min(parent.width, root.theme.space(20))
                                    height: root.maximum > 0 ? parent.height * dayColumn.entries / root.maximum : 0
                                    color: dayColumn.currentDay ? root.theme.accent : root.theme.secondary
                                    opacity: dayColumn.currentDay ? 0.85 : 0.5
                                    radius: root.theme.radius
                                }
                            }
                            DText {
                                theme: root.theme
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                Layout.preferredHeight: countMetrics.height
                                text: Qt.formatDate(new Date(dayColumn.date + "T12:00:00"), "d")
                                font.pixelSize: root.theme.small
                                color: dayColumn.currentDay ? root.theme.accent : root.theme.secondary
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.NoWrap
                                Accessible.ignored: true
                            }
                        }
                    }
                }
            }
        }
    }
    ColumnLayout {
        Layout.fillWidth: true
        visible: root.separateCounts
        spacing: root.theme.space(8)
        Repeater {
            model: root.separateCounts ? root.days || [] : []
            delegate: RowLayout {
                id: countRow
                required property var modelData
                required property int index
                readonly property real entries: root.counts && index < root.counts.length ? root.counts[index] : 0
                Layout.fillWidth: true
                spacing: root.theme.space(12)
                DText {
                    theme: root.theme
                    Layout.fillWidth: true
                    text: Display.day(countRow.modelData.date)
                    font.pixelSize: root.theme.small
                    color: root.theme.secondary
                    wrapMode: Text.Wrap
                    Accessible.ignored: true
                }
                DText {
                    theme: root.theme
                    Layout.maximumWidth: root.width / 2
                    text: String(countRow.entries)
                    font.pixelSize: root.theme.small
                    horizontalAlignment: Text.AlignRight
                    wrapMode: Text.WrapAnywhere
                    Accessible.ignored: true
                }
            }
        }
    }
}
