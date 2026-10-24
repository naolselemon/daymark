pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

FocusScope {
    id: root
    objectName: "timerView"
    required property var theme
    required property var controller
    property bool shortcutsEnabled: false
    property string digits: ""
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
        : controller.recovery === "reboot" ? "Paused after restart — resume when ready"
        : controller.status === "paused" ? "Paused"
        : controller.status === "running" ? "Counting down" : "A little time, just for you"

    function append(value) {
        if (!editing || !available) return;
        const next = ((controller.status === "finished" ? "" : digits) + value).replace(/^0+/, "");
        if (next.length <= 6) digits = next;
        if (controller.status === "finished") controller.reset();
    }
    function erase() { if (editing && available) digits = digits.slice(0, -1); }
    function preset(minutes) {
        if (!editing || !available) return;
        digits = String(minutes) + "00";
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
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: Math.min(timerScroll.availableWidth, root.theme.space(580))
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
            DText {
                theme: root.theme
                text: root.statusText
                font.italic: true
                color: root.controller.status === "finished" ? root.theme.accent : root.theme.secondary
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
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
                        Layout.preferredWidth: 1
                        spacing: root.theme.space(4)
                        DText {
                            theme: root.theme
                            text: root.field(timeField.index)
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Math.min(root.theme.space(88), Math.max(root.theme.space(36), root.width / 5))
                            color: root.controller.status === "finished" ? root.theme.accent : root.theme.foreground
                            Accessible.name: text + " " + timeField.modelData
                        }
                        DText {
                            theme: root.theme
                            text: timeField.modelData
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            color: root.theme.secondary
                            font.pixelSize: root.theme.small
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(8)
                Repeater {
                    model: [1, 5, 10, 15]
                    delegate: DButton {
                        required property int modelData
                        objectName: "countdownPreset" + modelData
                        theme: root.theme
                        text: modelData + "m"
                        font.pixelSize: root.theme.heading
                        Layout.preferredHeight: root.theme.space(56)
                        Accessible.name: modelData + " minute preset"
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        enabled: root.editing && root.available
                        onClicked: root.preset(modelData)
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                DButton {
                    objectName: "countdownPrimary"
                    theme: root.theme
                    text: root.controller.status === "running" ? "Pause timer"
                        : root.controller.status === "paused" ? "Resume timer" : "Start timer"
                    iconName: root.controller.status === "running" ? "pause" : "play"
                    primary: true
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.theme.space(64)
                    enabled: root.available && (!root.editing || root.validDuration)
                    shortcutHint: "Enter"
                    onClicked: root.primaryAction()
                }
                DButton {
                    objectName: "countdownReset"
                    theme: root.theme
                    text: root.editing ? "Reset timer" : "Cancel timer"
                    iconName: "reset"
                    enabled: root.available
                    onClicked: root.reset()
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
            GridLayout {
                columns: 3
                Layout.fillWidth: true
                columnSpacing: root.theme.space(12)
                rowSpacing: root.theme.space(4)
                visible: root.editing
                Repeater {
                    model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "00", "0", "back"]
                    delegate: DButton {
                        objectName: "countdownKey" + modelData
                        required property string modelData
                        theme: root.theme
                        text: modelData === "back" ? "Backspace" : modelData
                        iconName: modelData === "back" ? "backspace" : ""
                        quiet: true
                        font.pixelSize: root.theme.title
                        Layout.preferredHeight: root.theme.space(56)
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        enabled: root.available
                        onClicked: modelData === "back" ? root.erase() : root.append(modelData)
                    }
                }
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
