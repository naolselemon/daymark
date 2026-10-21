pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    objectName: "entryBars"
    required property var theme
    required property var days
    required property var counts
    readonly property real maximum: counts && counts.length ? Math.max(0, ...counts) : 0
    readonly property real columnWidth: days && days.length ? (width - theme.space(6) * (days.length - 1)) / days.length : 0
    readonly property bool separateCounts: !!(counts && counts.some(count => countMetrics.advanceWidth(String(count)) > columnWidth))
    spacing: theme.space(10)

    FontMetrics {
        id: countMetrics
        font.family: root.theme.family
        font.pixelSize: root.theme.small
    }

    Item {
        Layout.fillWidth: true
        implicitHeight: (root.separateCounts ? 0 : countMetrics.height + root.theme.space(8))
            + root.theme.space(88) + countMetrics.height + root.theme.space(8)

        // One plot area keeps every column on the same baseline, even when
        // exact counts need the roomier list below.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            y: parent.height - countMetrics.height - root.theme.space(8) - root.theme.space(44)
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
            spacing: root.theme.space(6)
            Repeater {
                model: root.days || []
                delegate: ColumnLayout {
                    id: dayColumn
                    required property var modelData
                    required property int index
                    readonly property real entries: root.counts && index < root.counts.length ? root.counts[index] : 0
                    // The canonical seven-day window always ends on today.
                    readonly property bool currentDay: index === root.days.length - 1
                    objectName: "entryBar-" + modelData.date
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.minimumWidth: 0
                    spacing: root.theme.space(8)
                    Accessible.role: Accessible.StaticText
                    Accessible.name: modelData.date + ": " + entries + (entries === 1 ? " entry" : " entries")

                    DText {
                        theme: root.theme
                        visible: !root.separateCounts
                        Layout.fillWidth: true
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
                        Layout.preferredHeight: root.theme.space(88)
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
                        Layout.preferredHeight: countMetrics.height
                        text: Qt.formatDate(new Date(dayColumn.modelData.date + "T12:00:00"), "d")
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
    ColumnLayout {
        Layout.fillWidth: true
        visible: root.separateCounts
        spacing: root.theme.space(6)
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
                    text: Qt.formatDate(new Date(countRow.modelData.date + "T12:00:00"), "ddd d")
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
