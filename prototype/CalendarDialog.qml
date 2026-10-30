pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    required property var controller
    property string savedName: ""
    property bool dismissPending: false
    property bool disconnectPending: false
    readonly property bool dirty: feedField.text !== "" || nameField.text !== savedName
    property bool setupExpanded: false
    property string notificationError: ""
    signal backRequested()
    objectName: "calendarDialog"
    modal: true
    focus: true
    anchors.centerIn: parent
    width: Math.max(0, Math.min(parent.width - theme.space(24), theme.space(580)))
    height: Math.max(0, Math.min(parent.height - theme.space(24), implicitHeight))
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(24)
    closePolicy: Popup.NoAutoClose
    palette.window: theme.background
    palette.windowText: theme.foreground
    palette.base: theme.controlSurface
    palette.text: theme.foreground
    palette.highlight: theme.accent
    palette.highlightedText: theme.accentText
    background: Rectangle { color: root.theme.surface; radius: root.theme.radius; border.color: root.theme.border }

    function begin() {
        if (opened) return;
        dismissPending = false;
        disconnectPending = false;
        if (!dirty) { savedName = controller.info.name; nameField.text = savedName; }
        open();
        if (!controller.loaded && !controller.busy) controller.loadStatus();
    }
    function requestDismiss() {
        if (controller.busy) return false;
        disconnectPending = false;
        if (dirty) { dismissPending = true; return false; }
        close();
        backRequested();
        return true;
    }
    function discardAndReturn() {
        if (controller.busy) return;
        feedField.clear();
        savedName = controller.info.name;
        nameField.text = savedName;
        dismissPending = false;
        close();
        backRequested();
    }
    function checkedLabel(seconds) {
        return seconds ? Qt.formatDateTime(new Date(seconds * 1000), "d MMM yyyy, HH:mm") : qsTr("Not yet checked");
    }
    onOpened: {
        scroll.ScrollBar.vertical.position = 0;
        backButton.forceActiveFocus(Qt.PopupFocusReason);
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.opened
        onActivated: root.requestDismiss()
    }
    Connections {
        target: root.controller
        function onOperationFinished(operation, success) {
            if (!success) return;
            if (operation === "calendar_configure" || operation === "calendar_disconnect") {
                feedField.clear();
                root.savedName = root.controller.info.name;
                nameField.text = root.savedName;
                root.disconnectPending = false;
                root.dismissPending = false;
            }
        }
    }
    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(12)
        RowLayout {
            Layout.fillWidth: true; spacing: root.theme.space(12)
            DButton {
                id: backButton
                theme: root.theme; text: qsTr("Back to Settings"); iconName: "previous"; quiet: true
                objectName: "calendarBack"; enabled: !root.controller.busy
                onClicked: root.requestDismiss()
            }
            DText {
                theme: root.theme; text: qsTr("Calendars"); font.pixelSize: root.theme.title; font.italic: true
                Layout.fillWidth: true; Layout.minimumWidth: 0
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 0
            Layout.preferredHeight: sections.implicitHeight + padding * 2
            contentWidth: availableWidth
            padding: root.theme.space(3)
            clip: true
            focusPolicy: Qt.StrongFocus
            Accessible.name: qsTr("Calendar settings")
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: sections
                width: scroll.availableWidth
                spacing: root.theme.space(12)
                DText { theme: root.theme; text: qsTr("Google Calendar · read only"); font.bold: true; color: root.theme.secondary; Layout.fillWidth: true }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary; font.pixelSize: root.theme.small
                    text: qsTr("See upcoming events in Today and Plan. Events never become entries or completed activities, and Daymark cannot change your calendar.")
                }
                ColumnLayout {
                    visible: root.controller.configured
                    Layout.fillWidth: true; spacing: root.theme.space(6)
                    DText { theme: root.theme; text: root.controller.info.name || qsTr("Google Calendar"); Layout.fillWidth: true; font.bold: true }
                    DText { theme: root.theme; text: root.controller.statusText; color: root.theme.secondary; Layout.fillWidth: true; objectName: "calendarStatus" }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary; font.pixelSize: root.theme.small
                        text: qsTr("Last checked: %1").arg(root.checkedLabel(root.controller.info.lastCheckedAt))
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary; font.pixelSize: root.theme.small
                        text: qsTr("Reminders show event titles at their start time while Daymark is enabled. All-day events and missed reminders stay quiet.")
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.urgent; font.pixelSize: root.theme.small
                        visible: text !== ""; text: root.notificationError
                        objectName: "calendarNotificationError"
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary; font.pixelSize: root.theme.small
                        visible: root.controller.stale && root.controller.info.lastSuccessAt > 0
                        text: qsTr("Last updated: %1").arg(root.checkedLabel(root.controller.info.lastSuccessAt))
                    }
                    DText {
                        theme: root.theme; text: root.controller.windowLabel; Layout.fillWidth: true
                        color: root.theme.secondary; font.pixelSize: root.theme.small; visible: text !== ""
                        objectName: "calendarWindow"
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: root.theme.space(8)
                        DButton {
                            theme: root.theme; text: qsTr("Refresh"); iconName: "retry"; iconOnly: false; quiet: true
                            objectName: "calendarRefresh"; enabled: !root.controller.busy && root.controller.info.enabled
                            onClicked: root.controller.refresh()
                        }
                        DButton {
                            theme: root.theme; text: qsTr("Disconnect"); iconName: "close"; iconOnly: false; quiet: true
                            objectName: "calendarDisconnect"; enabled: !root.controller.busy
                            onClicked: { root.dismissPending = false; root.disconnectPending = true; }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                DButton {
                    id: setupToggle
                    theme: root.theme; Layout.fillWidth: true
                    text: qsTr("Calendar setup instructions")
                    iconName: root.setupExpanded ? "collapse" : "expand"; iconOnly: false; quiet: true
                    objectName: "calendarSetupToggle"
                    Accessible.description: qsTr("Show or hide optional dependency installation and private Google Calendar address instructions.")
                    onClicked: root.setupExpanded = !root.setupExpanded
                }
                ColumnLayout {
                    visible: root.setupExpanded
                    Layout.fillWidth: true; spacing: root.theme.space(8)
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.bold: true
                        text: qsTr("1. Install optional calendar support once")
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                        text: qsTr("Run these commands in your terminal once to install icalendar and recurring-ical-events in an isolated user environment, not system Python. Do not use sudo. Daymark only displays these commands; it does not run or install anything.")
                    }
                    DArea {
                        id: setupCommands
                        theme: root.theme; Layout.fillWidth: true
                        objectName: "calendarSetupCommands"
                        readOnly: true; wrapMode: TextEdit.WrapAnywhere
                        font.pixelSize: root.theme.small
                        Accessible.name: qsTr("Optional calendar setup commands")
                        text: 'runtime="${XDG_DATA_HOME:-$HOME/.local/share}/daylog-calendar-runtime"\n'
                            + 'python -m venv "$runtime"\n'
                            + '"$runtime/bin/python" -m pip install -r "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/naolselemon.daymark/requirements-calendar.txt"'
                    }
                    DButton {
                        theme: root.theme; text: qsTr("Copy commands"); iconName: "pages"; iconOnly: false
                        objectName: "calendarCopySetup"
                        onClicked: { setupCommands.selectAll(); setupCommands.copy(); setupCommands.deselect(); }
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                        text: qsTr("When installation finishes, retry Connect (or Replace calendar). A missing-dependencies error does not mean your calendar address is wrong; your unsaved address stays here while you set up support.")
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.bold: true
                        text: qsTr("2. Find your private Google Calendar address")
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                        text: qsTr("In Chrome or another desktop browser:\n1. Open calendar.google.com and sign in.\n2. Open the gear menu → Settings.\n3. Under Settings for my calendars, choose the calendar.\n4. Open Integrate calendar.\n5. Copy Secret address in iCal format and paste it below.\nOn mobile, request the browser’s desktop site if these settings are not visible.")
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small; color: root.theme.secondary
                        text: qsTr("Use the secret iCal address, not the calendar ID, embed code, or an API key. Do not make your calendar public. Keep this address private: anyone with it can read the calendar. Managed work or school accounts may restrict access to secret addresses; ask your administrator if it is missing.")
                    }
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary; font.pixelSize: root.theme.small
                    text: root.controller.configured ? qsTr("To replace this calendar, enter another private iCal address. The saved address is never shown.")
                        : qsTr("In Google Calendar settings, copy the Secret address in iCal format from Integrate calendar. Keep this address private: anyone with it can read the calendar.")
                }
                DField {
                    id: feedField
                    theme: root.theme; Layout.fillWidth: true; objectName: "calendarFeedUrl"
                    placeholderText: qsTr("Private iCal address")
                    echoMode: TextInput.Password
                    passwordMaskDelay: 0
                    inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    enabled: !root.controller.busy && !root.dismissPending && !root.disconnectPending
                    onTextEdited: root.dismissPending = false
                }
                DField {
                    id: nameField
                    theme: root.theme; Layout.fillWidth: true; objectName: "calendarFeedName"
                    placeholderText: qsTr("Calendar name · optional")
                    enabled: feedField.enabled
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary; font.pixelSize: root.theme.small
                    text: qsTr("Connect checks the feed first. Once connected, Daymark refreshes it hourly. The private address is stored locally and is not included in journal exports.")
                }
                DButton {
                    theme: root.theme; text: root.controller.configured ? qsTr("Replace calendar") : qsTr("Connect")
                    iconName: "calendar"; iconOnly: false; primary: true; objectName: "calendarConnect"
                    enabled: !root.controller.busy && feedField.text.trim() !== "" && !root.dismissPending && !root.disconnectPending
                    onClicked: root.controller.configure(feedField.text, nameField.text)
                }
                DText {
                    theme: root.theme; text: root.controller.error; color: root.theme.urgent; Layout.fillWidth: true
                    visible: text !== ""; objectName: "calendarError"; font.pixelSize: root.theme.small
                }
                DButton {
                    theme: root.theme; text: qsTr("Help with calendar setup"); iconName: "expand"; iconOnly: false; quiet: true
                    visible: root.controller.error !== ""; objectName: "calendarErrorSetup"
                    onClicked: { root.setupExpanded = true; setupToggle.forceActiveFocus(Qt.TabFocusReason); }
                }
                DButton {
                    theme: root.theme; text: qsTr("Retry loading"); iconName: "retry"; iconOnly: false; quiet: true
                    objectName: "calendarRetryStatus"; visible: !root.controller.loaded && root.controller.error !== ""
                    enabled: !root.controller.busy; onClicked: root.controller.loadStatus()
                }
                RowLayout {
                    Layout.fillWidth: true; visible: root.controller.busy
                    DText { theme: root.theme; text: qsTr("Working…"); color: root.theme.secondary; Layout.fillWidth: true }
                    DButton {
                        theme: root.theme; text: qsTr("Cancel request"); iconName: "close"; iconOnly: false; quiet: true
                        objectName: "calendarCancelRequest"; onClicked: root.controller.cancel()
                        enabled: !root.controller.cancelRequested
                    }
                }
                ColumnLayout {
                    visible: root.disconnectPending; Layout.fillWidth: true; spacing: root.theme.space(8)
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                    DText {
                        theme: root.theme; Layout.fillWidth: true
                        text: qsTr("Disconnect and remove the saved address and calendar events from Daymark? Your Google Calendar and journal entries will not change.")
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: root.theme.space(8)
                        DButton { theme: root.theme; text: qsTr("Keep connected"); iconOnly: false; enabled: !root.controller.busy; onClicked: root.disconnectPending = false }
                        DButton {
                            theme: root.theme; text: qsTr("Disconnect calendar"); iconOnly: false
                            objectName: "calendarConfirmDisconnect"; enabled: !root.controller.busy
                            onClicked: root.controller.disconnectFeed()
                        }
                    }
                }
                ColumnLayout {
                    visible: root.dismissPending; Layout.fillWidth: true; spacing: root.theme.space(8)
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                    DText { theme: root.theme; text: qsTr("Discard the unsaved calendar address and name?"); Layout.fillWidth: true }
                    Flow {
                        Layout.fillWidth: true; spacing: root.theme.space(8)
                        DButton { theme: root.theme; text: qsTr("Keep editing"); iconOnly: false; objectName: "calendarKeepEditing"; onClicked: root.dismissPending = false }
                        DButton { theme: root.theme; text: qsTr("Discard draft"); iconOnly: false; objectName: "calendarDiscardDraft"; onClicked: root.discardAndReturn() }
                    }
                }
            }
        }
    }
}
