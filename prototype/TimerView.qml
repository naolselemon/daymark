pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import "Focus.js" as Focus

FocusScope {
    id: root
    objectName: "timerView"
    required property var theme
    required property var controller
    property bool shortcutsEnabled: false
    property string digits: ""
    property bool durationExpanded: false
    readonly property int totalSeconds: controller.status === "idle" ? inputSeconds : controller.durationSeconds
    readonly property real remainingFraction: controller.status === "finished" ? 0
        : editing ? (validDuration ? 1 : 0)
        : totalSeconds > 0 ? Math.max(0, Math.min(1, controller.remainingSeconds / totalSeconds)) : 0
    readonly property bool editing: controller.status === "idle" || controller.status === "finished"
    readonly property string padded: ("000000" + digits).slice(-6)
    readonly property int hours: Number(padded.slice(0, 2))
    readonly property int minutes: Number(padded.slice(2, 4))
    readonly property int seconds: Number(padded.slice(4, 6))
    readonly property bool validDuration: minutes < 60 && seconds < 60 && inputSeconds > 0
    readonly property int inputSeconds: hours * 3600 + minutes * 60 + seconds
    readonly property int shownSeconds: editing ? (controller.status === "finished" ? 0 : inputSeconds) : controller.remainingSeconds
    readonly property bool available: controller.loaded && !controller.busy && !controller.error
    readonly property string statusText: controller.status === "finished" ? "Time is up"
        : controller.status === "paused" ? "Paused"
        : controller.status === "running" ? "Running" : "Ready"

    function append(value) {
        if (!editing || !available) return;
        const next = ((controller.status === "finished" ? "" : digits) + value).replace(/^0+/, "");
        if (next.length <= 6) digits = next;
        if (controller.status === "finished") controller.reset();
    }
    function erase() { if (editing && available) digits = digits.slice(0, -1); }
    function preset(minutes) {
        if (!editing || !available) return;
        digits = String(Math.floor(minutes / 60) * 10000 + (minutes % 60) * 100);
        if (controller.status === "finished") controller.reset();
    }
    function primaryAction() {
        if (!available) return;
        if (controller.status === "running") controller.pause();
        else if (controller.status === "paused") controller.resume();
        else if (validDuration) controller.start(inputSeconds);
    }
    function reset() {
        if (!available) return;
        digits = "";
        controller.reset();
    }
    function pair(value) { return ("0" + value).slice(-2); }
    function field(index) {
        if (editing && controller.status !== "finished") return padded.slice(index * 2, index * 2 + 2);
        return pair(index === 0 ? Math.floor(shownSeconds / 3600)
                    : index === 1 ? Math.floor(shownSeconds / 60) % 60 : shownSeconds % 60);
    }
    function durationText() {
        if (controller.status === "idle") return field(0) + ":" + field(1) + ":" + field(2);
        return pair(Math.floor(totalSeconds / 3600)) + ":" + pair(Math.floor(totalSeconds / 60) % 60)
            + ":" + pair(totalSeconds % 60);
    }

    Repeater {
        model: 10
        delegate: Item {
            id: digitShortcut
            required property int index
            Shortcut {
                sequence: String(digitShortcut.index)
                enabled: root.visible && root.shortcutsEnabled && root.editing
                autoRepeat: false
                onActivated: root.append(String(digitShortcut.index))
            }
        }
    }
    Shortcut {
        sequence: "Backspace"
        enabled: root.visible && root.shortcutsEnabled && root.editing
        onActivated: root.erase()
    }
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: root.visible && root.shortcutsEnabled
        autoRepeat: false
        onActivated: root.primaryAction()
    }

    ScrollView {
        id: timerScroll
        objectName: "timerScroll"
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: Math.min(timerScroll.availableWidth, root.theme.space(1040))
            x: Math.max(0, (timerScroll.availableWidth - width) / 2)
            spacing: root.theme.space(16)
            RowLayout {
                Layout.fillWidth: true
                DText {
                    theme: root.theme
                    text: "Timer"
                    font.pixelSize: root.theme.pageTitle
                    font.italic: true
                    Layout.fillWidth: true
                }
                DButton {
                    objectName: "countdownMute"
                    theme: root.theme
                    text: root.controller.muted ? "Unmute completion sound" : "Mute completion sound"
                    iconName: root.controller.muted ? "mute" : "sound"
                    selected: root.controller.muted
                    enabled: root.available
                    onClicked: root.controller.toggleMute()
                }
            }
            GridLayout {
                id: timerLayout
                objectName: "timerLayout"
                readonly property bool sideBySide: width >= root.theme.space(760) && root.durationExpanded
                // About 4 cm at standard desktop density; reduce the inset on short viewports.
                readonly property real verticalOffset: Math.min(root.theme.space(152),
                    Math.max(0, timerScroll.availableHeight - root.theme.space(450)))
                Layout.topMargin: verticalOffset
                columns: sideBySide ? 2 : 1
                columnSpacing: root.theme.space(40)
                rowSpacing: root.theme.space(24)
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.maximumWidth: Infinity
                ColumnLayout {
                    id: orbitColumn
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.maximumWidth: Infinity
                    Layout.preferredWidth: root.theme.space(460)
                    Layout.alignment: Qt.AlignTop
                    // Center against the circle, excluding the presets underneath.
                    Layout.topMargin: timerLayout.sideBySide
                        ? Math.max(0, (durationPanel.implicitHeight - orbit.height) / 2) : 0
                    spacing: root.theme.space(20)
                    Item {
                        id: orbit
                        objectName: "countdownOrbit"
                        Layout.preferredWidth: Math.min(orbitColumn.width, root.theme.space(400),
                            Math.max(root.theme.space(280), timerScroll.availableHeight
                                - root.theme.space(timerLayout.sideBySide ? 184 : 280)))
                        Layout.preferredHeight: width
                        Layout.alignment: Qt.AlignHCenter
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: root.theme.surface
                            border.color: root.theme.controlSurface
                            border.width: root.theme.space(6)
                        }
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            visible: root.remainingFraction > 0
                            Accessible.ignored: true
                            ShapePath {
                                fillColor: "transparent"
                                strokeColor: root.theme.accent
                                strokeWidth: root.theme.space(6)
                                capStyle: ShapePath.FlatCap
                                PathAngleArc {
                                    centerX: orbit.width / 2
                                    centerY: orbit.height / 2
                                    radiusX: (orbit.width - root.theme.space(6)) / 2
                                    radiusY: radiusX
                                    startAngle: -90
                                    sweepAngle: 360 * root.remainingFraction
                                }
                            }
                        }
                        ColumnLayout {
                            anchors.centerIn: parent
                            width: parent.width * 0.72
                            spacing: root.theme.space(12)
                            DText {
                                theme: root.theme
                                text: root.statusText
                                font.italic: true
                                font.pixelSize: root.theme.small
                                color: root.controller.status === "running" || root.controller.status === "finished"
                                    ? root.theme.accent : root.theme.secondary
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                Accessible.role: Accessible.StaticText
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: root.theme.space(12)
                                Repeater {
                                    model: ["Hours", "Minutes", "Seconds"]
                                    delegate: ColumnLayout {
                                        id: timeField
                                        required property string modelData
                                        required property int index
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        Layout.preferredWidth: 1
                                        spacing: root.theme.space(4)
                                        DText {
                                            theme: root.theme
                                            text: root.field(timeField.index)
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            font.pixelSize: Math.min(root.theme.space(54), orbit.width / 8)
                                            color: root.controller.status === "finished" ? root.theme.accent : root.theme.foreground
                                            Accessible.name: text + " " + timeField.modelData
                                        }
                                        DText {
                                            theme: root.theme
                                            text: ["HH", "MM", "SS"][timeField.index]
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            color: root.theme.secondary
                                            font.pixelSize: root.theme.small
                                            Accessible.ignored: true
                                        }
                                    }
                                }
                            }
                            DText {
                                theme: root.theme
                                text: "of " + root.durationText()
                                visible: root.controller.status !== "idle"
                                color: root.theme.secondary
                                font.pixelSize: root.theme.small
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.maximumWidth: root.theme.space(200)
                                Layout.alignment: Qt.AlignHCenter
                                spacing: root.theme.space(8)
                                DButton {
                                    objectName: "countdownPrimary"
                                    theme: root.theme
                                    text: root.controller.status === "running" ? "Pause timer"
                                        : root.controller.status === "paused" ? "Resume timer" : "Start timer"
                                    iconName: root.controller.status === "running" ? "pause" : "play"
                                    primary: true
                                    Layout.fillWidth: true
                                    enabled: root.available && (!root.editing || root.validDuration)
                                    shortcutHint: "Enter"
                                    onClicked: root.primaryAction()
                                }
                                DButton {
                                    objectName: "countdownReset"
                                    theme: root.theme
                                    text: root.editing ? "Reset timer" : "Cancel timer"
                                    iconName: root.editing ? "reset" : "close"
                                    enabled: root.available
                                    onClicked: root.reset()
                                }
                            }
                        }
                    }
                    GridLayout {
                        objectName: "countdownPresets"
                        columns: width >= root.theme.space(340) ? 4 : 2
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        Layout.maximumWidth: root.theme.space(460)
                        Layout.alignment: Qt.AlignHCenter
                        columnSpacing: root.theme.space(8)
                        rowSpacing: root.theme.space(8)
                        Repeater {
                            model: [5, 15, 30, 60]
                            delegate: DButton {
                                required property int modelData
                                objectName: "countdownPreset" + modelData
                                theme: root.theme
                                text: modelData + "m"
                                selected: root.totalSeconds === modelData * 60
                                Layout.preferredHeight: root.theme.space(48)
                                Accessible.name: modelData + " minute preset"
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                enabled: root.editing && root.available
                                onClicked: root.preset(modelData)
                            }
                        }
                    }
                }
                Rectangle {
                    id: durationPanel
                    objectName: "countdownDurationPanel"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.preferredWidth: root.theme.space(320)
                    Layout.maximumWidth: root.theme.space(timerLayout.sideBySide ? 360 : 460)
                    Layout.alignment: Qt.AlignTop | Qt.AlignHCenter
                    Layout.topMargin: timerLayout.sideBySide
                        ? Math.max(0, (orbit.height - implicitHeight) / 2) : 0
                    implicitHeight: durationContents.implicitHeight + root.theme.space(32)
                    color: root.theme.surface
                    border.color: root.theme.border
                    radius: root.theme.radius
                    ColumnLayout {
                        id: durationContents
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.top: parent.top; anchors.margins: root.theme.space(16)
                        spacing: root.theme.space(12)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: root.theme.space(12)
                            DIcon {
                                name: "keyboard"; color: root.theme.secondary
                                Layout.preferredWidth: root.theme.space(22)
                                Layout.preferredHeight: root.theme.space(22)
                            }
                            DText {
                                theme: root.theme
                                text: "Duration"
                                Layout.fillWidth: true
                            }
                            DButton {
                                id: durationToggle
                                objectName: "countdownDurationToggle"
                                theme: root.theme
                                text: root.durationExpanded ? "Hide duration keypad" : "Show duration keypad"
                                iconName: root.durationExpanded ? "collapse" : "expand"
                                quiet: true
                                checkable: true
                                checked: root.durationExpanded
                                onClicked: {
                                    root.durationExpanded = checked;
                                    Qt.callLater(() => Focus.reveal(durationToggle));
                                }
                            }
                        }
                        DText {
                            theme: root.theme
                            text: root.durationText()
                            font.pixelSize: root.theme.title
                            Layout.fillWidth: true
                            visible: root.durationExpanded
                            Accessible.name: "Duration " + text
                        }
                        GridLayout {
                            columns: 3
                            Layout.fillWidth: true
                            columnSpacing: root.theme.space(8)
                            rowSpacing: root.theme.space(8)
                            visible: root.durationExpanded
                            Repeater {
                                model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "00", "0", "back"]
                                delegate: DButton {
                                    objectName: "countdownKey" + modelData
                                    required property string modelData
                                    theme: root.theme
                                    text: modelData === "back" ? "Backspace" : modelData
                                    iconName: modelData === "back" ? "backspace" : ""
                                    font.pixelSize: root.theme.heading
                                    Layout.preferredHeight: root.theme.space(56)
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    enabled: root.editing && root.available
                                    onClicked: modelData === "back" ? root.erase() : root.append(modelData)
                                }
                            }
                        }
                    }
                }
            }
            DText {
                theme: root.theme
                text: "Minutes and seconds must be 00–59. Maximum 99:59:59."
                color: root.theme.urgent
                visible: root.editing && (root.minutes > 59 || root.seconds > 59)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
            DText {
                theme: root.theme
                text: "Paused after restart — resume when ready"
                visible: root.controller.recovery === "reboot"
                color: root.theme.secondary
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
            DText {
                theme: root.theme
                text: root.controller.error || root.controller.soundUnavailable
                visible: text !== ""
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: root.controller.error ? root.theme.urgent : root.theme.secondary
                font.pixelSize: root.theme.small
            }
            DButton {
                theme: root.theme
                text: "Retry countdown"
                iconName: "restore"
                visible: !!root.controller.error
                enabled: !root.controller.busy
                onClicked: root.controller.retry()
            }
            DText {
                theme: root.theme
                text: root.controller.busy ? "Saving timer…" : "Independent of your activities and diary"
                font.pixelSize: root.theme.small
                font.italic: true
                color: root.theme.secondary
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            Item { Layout.preferredHeight: root.theme.space(8) }
        }
    }
}
