pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import "Focus.js" as Focus

FocusScope {
    id: root
    objectName: "timerView"
    required property var theme
    required property var controller
    property var store: null
    signal targetRequested()
    signal logRequested()
    readonly property bool finished: controller.status === "finished"
    readonly property bool linkedFinished: finished && !!controller.activityId
    property bool finishedDraft: false
    onFinishedChanged: finishedDraft = false
    onLinkedFinishedChanged: if (linkedFinished) finishedDraft = false
    readonly property var selectedActivity: store ? store.activity(controller.selectedActivityId || "") : null
    readonly property var selectedTask: selectedActivity
        ? (selectedActivity.tasks || []).find(task => task.id === controller.selectedTaskId) : null
    readonly property string targetTitle: controller.status !== "idle"
        ? controller.activityTitle || qsTr("No activity")
        : selectedActivity ? selectedActivity.title : controller.selectedActivityId
            ? qsTr("Activity unavailable") : qsTr("No activity")
    readonly property string targetSubtitle: controller.status !== "idle"
        ? controller.taskTitle || (controller.activityId ? qsTr("Whole activity") : qsTr("A standalone countdown"))
        : selectedTask ? selectedTask.title : controller.selectedTaskId
            ? qsTr("Task unavailable") : selectedActivity ? qsTr("Whole activity") : qsTr("Activity / task is optional")
    property bool shortcutsEnabled: false
    property string digits: ""
    property bool durationExpanded: false
    readonly property int totalSeconds: controller.status === "idle" || finishedDraft ? inputSeconds : controller.durationSeconds
    readonly property real remainingFraction: controller.status === "finished" ? 0
        : editing ? (validDuration ? 1 : 0)
        : totalSeconds > 0 ? Math.max(0, Math.min(1, controller.remainingSeconds / totalSeconds)) : 0
    readonly property bool editing: controller.status === "idle" || (controller.status === "finished" && !linkedFinished)
    // A draft's own reset must not swallow subsequent keystrokes. Actions still
    // wait for availability; unrelated operations keep the fields read-only.
    readonly property bool durationEditable: editing && !controller.logPending
        && (available || (finishedDraft && controller.loaded && controller.busy && !controller.error))
    readonly property bool textInputFocused: {
        const item = root.Window.window ? root.Window.window.activeFocusItem : null;
        return item instanceof TextInput || item instanceof TextEdit;
    }
    readonly property string padded: ("000000" + digits).slice(-6)
    readonly property int hours: Number(padded.slice(0, 2))
    readonly property int minutes: Number(padded.slice(2, 4))
    readonly property int seconds: Number(padded.slice(4, 6))
    readonly property bool validDuration: /^[0-9]{1,6}$/.test(digits) && minutes < 60 && seconds < 60 && inputSeconds > 0
    readonly property int inputSeconds: hours * 3600 + minutes * 60 + seconds
    readonly property int shownSeconds: editing ? (finished && !finishedDraft ? 0 : inputSeconds) : controller.remainingSeconds
    readonly property bool available: controller.loaded && !controller.busy && !controller.error
    readonly property string statusText: controller.status === "finished" ? "Time is up"
        : controller.status === "paused" ? "Paused"
        : controller.status === "running" ? "Running" : "Ready"

    function setInput(next) {
        if (!durationEditable) return;
        // Reset a standalone completion once, retaining input throughout the
        // asynchronous save. Its second digit may arrive before the reply.
        const resetFinished = finished && !finishedDraft;
        if (finished) finishedDraft = true;
        digits = next;
        if (resetFinished) controller.reset();
    }
    function append(value) {
        if (!durationEditable) return;
        const next = ((finished && !finishedDraft ? "" : digits) + value).replace(/^0+/, "");
        if (next.length <= 6) setInput(next);
    }
    function erase() { if (durationEditable) setInput(digits.slice(0, -1)); }
    function preset(minutes) {
        if (!durationEditable) return;
        setInput(String(Math.floor(minutes / 60) * 10000 + (minutes % 60) * 100));
    }
    function primaryAction() {
        if (!available || controller.logPending) return;
        if (controller.status === "running") controller.pause();
        else if (controller.status === "paused") controller.resume();
        else if (editing && validDuration) controller.start(inputSeconds);
    }
    function reset() {
        if (!available || controller.logPending) return;
        finishedDraft = false;
        digits = "";
        controller.reset();
    }
    function pair(value) { return ("0" + value).slice(-2); }
    function field(index) {
        if (editing && (!finished || finishedDraft)) return padded.slice(index * 2, index * 2 + 2);
        return pair(index === 0 ? Math.floor(shownSeconds / 3600)
                    : index === 1 ? Math.floor(shownSeconds / 60) % 60 : shownSeconds % 60);
    }
    function durationText() {
        if (controller.status === "idle" || finishedDraft) return field(0) + ":" + field(1) + ":" + field(2);
        return pair(Math.floor(totalSeconds / 3600)) + ":" + pair(Math.floor(totalSeconds / 60) % 60)
            + ":" + pair(totalSeconds % 60);
    }
    function durationField(index) {
        return durationText().slice(index * 3, index * 3 + 2);
    }
    function editUnit(index, value, durationReadout) {
        if (!durationEditable || index < 0 || index > 2 || !/^[0-9]{0,2}$/.test(value)) return;
        const base = finished && !finishedDraft
            ? (durationReadout ? durationText().replace(/:/g, "") : "000000") : padded;
        const offset = index * 2;
        const next = base.slice(0, offset) + pair(Number(value)) + base.slice(offset + 2);
        setInput(String(next).replace(/^0+/, ""));
    }

    Repeater {
        model: 10
        delegate: Item {
            id: digitShortcut
            required property int index
            Shortcut {
                sequence: String(digitShortcut.index)
                enabled: root.visible && root.shortcutsEnabled && root.durationEditable && !root.textInputFocused
                autoRepeat: false
                onActivated: root.append(String(digitShortcut.index))
            }
        }
    }
    Shortcut {
        sequence: "Backspace"
        enabled: root.visible && root.shortcutsEnabled && root.durationEditable && !root.textInputFocused
        onActivated: root.erase()
    }
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: root.visible && root.shortcutsEnabled && !root.textInputFocused
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
            DButton {
                objectName: "countdownTarget"
                theme: root.theme
                text: root.targetTitle + " · " + root.targetSubtitle
                implicitHeight: Math.max(root.theme.space(64), targetContent.implicitHeight + topPadding + bottomPadding + 2)
                Layout.fillWidth: true
                Layout.maximumWidth: root.theme.space(460)
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: root.theme.space(24)
                enabled: root.available && root.controller.status === "idle" && !root.controller.logPending
                contentItem: RowLayout {
                    id: targetContent
                    spacing: root.theme.space(12)
                    DIcon {
                        name: "link"; color: root.theme.accent
                        Layout.preferredWidth: root.theme.space(24); Layout.preferredHeight: width
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        spacing: root.theme.space(4)
                        DText { theme: root.theme; text: root.targetTitle; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                        DText { theme: root.theme; text: root.targetSubtitle; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap; font.pixelSize: root.theme.small; color: root.theme.secondary }
                    }
                    DIcon {
                        name: "expand"; color: root.theme.secondary
                        Layout.preferredWidth: root.theme.space(20); Layout.preferredHeight: width
                    }
                }
                onClicked: root.targetRequested()
            }
            DText {
                theme: root.theme
                text: root.controller.targetError || (root.controller.status === "running" || root.controller.status === "paused"
                    ? qsTr("Cancel this countdown before choosing another target.") : "")
                visible: text !== ""
                Layout.fillWidth: true
                Layout.maximumWidth: root.theme.space(460)
                Layout.alignment: Qt.AlignHCenter
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: root.theme.small
                color: root.controller.targetError ? root.theme.urgent : root.theme.secondary
            }
            GridLayout {
                id: timerLayout
                objectName: "timerLayout"
                readonly property bool sideBySide: !root.linkedFinished && width >= root.theme.space(760) && root.durationExpanded
                // Reserve the lower space for finish actions rather than disabled duration controls.
                readonly property real verticalOffset: root.linkedFinished ? 0 : Math.min(root.theme.space(36),
                    Math.max(0, timerScroll.availableHeight - root.theme.space(560)))
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
                                - root.theme.space(root.linkedFinished ? 380 : timerLayout.sideBySide ? 184 : 280)))
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
                                        TimerUnitField {
                                            objectName: "countdown" + timeField.modelData
                                            theme: root.theme
                                            value: root.field(timeField.index)
                                            unitName: timeField.modelData
                                            maximum: timeField.index === 0 ? 99 : 59
                                            editable: root.durationEditable
                                            liveDisplay: !root.editing
                                            Layout.fillWidth: true
                                            font.pixelSize: Math.min(root.theme.space(54), orbit.width / 8)
                                            color: root.controller.status === "finished" ? root.theme.accent
                                                : !validUnit && editable ? root.theme.urgent : root.theme.foreground
                                            onEdited: value => root.editUnit(timeField.index, value, false)
                                            onSubmitted: root.primaryAction()
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
                                    enabled: root.available && !root.controller.logPending && !root.linkedFinished && (!root.editing || root.validDuration)
                                    shortcutHint: "Enter"
                                    onClicked: root.primaryAction()
                                }
                                DButton {
                                    objectName: "countdownReset"
                                    theme: root.theme
                                    text: root.linkedFinished ? qsTr("Dismiss timer") : root.editing ? "Reset timer" : "Cancel timer"
                                    iconName: root.editing ? "reset" : "close"
                                    enabled: root.available && !root.controller.logPending
                                    onClicked: root.reset()
                                }
                            }
                        }
                    }
                    GridLayout {
                        objectName: "countdownPresets"
                        visible: !root.linkedFinished
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
                                enabled: root.durationEditable
                                onClicked: root.preset(modelData)
                            }
                        }
                    }
                }
                Rectangle {
                    visible: !root.linkedFinished
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
                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.durationExpanded
                            spacing: 0
                            Repeater {
                                model: ["Hours", "Minutes", "Seconds"]
                                delegate: RowLayout {
                                    id: durationField
                                    required property string modelData
                                    required property int index
                                    spacing: 0
                                    TimerUnitField {
                                        objectName: "countdownDuration" + durationField.modelData
                                        theme: root.theme
                                        value: root.durationField(durationField.index)
                                        unitName: qsTr("Duration %1").arg(durationField.modelData)
                                        maximum: durationField.index === 0 ? 99 : 59
                                        editable: root.durationEditable
                                        liveDisplay: !root.editing
                                        font.pixelSize: root.theme.title
                                        onEdited: value => root.editUnit(durationField.index, value, true)
                                        onSubmitted: root.primaryAction()
                                    }
                                    DText {
                                        theme: root.theme
                                        text: ":"
                                        font.pixelSize: root.theme.title
                                        visible: durationField.index < 2
                                        Accessible.ignored: true
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
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
                                    enabled: root.durationEditable
                                    onClicked: modelData === "back" ? root.erase() : root.append(modelData)
                                }
                            }
                        }
                    }
                }
            }
            Rectangle {
                visible: root.linkedFinished
                Layout.fillWidth: true
                Layout.maximumWidth: root.theme.space(460)
                Layout.alignment: Qt.AlignHCenter
                implicitHeight: finishContents.implicitHeight + root.theme.space(40)
                color: root.theme.surface
                border.color: root.theme.border
                radius: root.theme.radius
                ColumnLayout {
                    id: finishContents
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: root.theme.space(20)
                    spacing: root.theme.space(16)
                    DText {
                        theme: root.theme
                        text: root.controller.logSaved ? qsTr("Entry saved") : qsTr("Timer finished")
                        font.pixelSize: root.theme.title
                        font.italic: true
                        Layout.fillWidth: true
                    }
                    DText {
                        theme: root.theme
                        text: root.controller.logSaved ? qsTr("Your untimed entry is in the journal.")
                            : root.controller.logPending ? qsTr("An entry is pending. Retry its unchanged details to confirm the save.")
                            : qsTr("Nothing logged yet. Logging does not complete the activity unless you choose it.")
                        color: root.theme.secondary
                        font.pixelSize: root.theme.small
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(12)
                        DButton {
                            objectName: "countdownDismiss"
                            theme: root.theme; text: qsTr("Dismiss")
                            enabled: root.available && !root.controller.logPending
                            onClicked: root.reset()
                        }
                        Item { Layout.fillWidth: true }
                        DButton {
                            objectName: "countdownLog"
                            theme: root.theme
                            text: root.controller.logPending ? qsTr("Retry entry") : qsTr("Log entry")
                            iconName: "log"; iconOnly: false; primary: true
                            visible: !root.controller.logSaved
                            enabled: root.available && (!root.controller.targetError || root.controller.logPending)
                            onClicked: root.logRequested()
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
                text: root.controller.busy ? "Saving timer…" : qsTr("Entries are untimed. Completion is always your choice.")
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
