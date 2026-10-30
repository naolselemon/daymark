pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    required property var preferences
    required property var countdown
    required property var updater
    property string cleanupBlockReason: ""
    signal cleanupRequested(string operation)
    property string approvalCommit: ""
    property string approvalVersion: ""
    readonly property var updateInfo: updater.info || ({})
    readonly property bool installing: updater.applying
    readonly property bool preferencesEditable: preferences.loaded && !preferences.busy && !preferences.error
    readonly property bool confirmationValid: approvalCommit !== "" && updateInfo.phase === "ready"
        && approvalCommit === updateInfo.availableCommit
    signal dataRequested()
    signal calendarsRequested()
    signal restartRequested(string commit)
    objectName: "settingsDialog"
    modal: true
    focus: true
    anchors.centerIn: parent
    width: Math.max(0, Math.min(parent.width - theme.space(24), theme.space(580)))
    height: Math.max(0, Math.min(parent.height - theme.space(24), implicitHeight))
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(24)
    palette.window: theme.background
    palette.windowText: theme.foreground
    palette.base: theme.controlSurface
    palette.text: theme.foreground
    palette.button: theme.controlSurface
    palette.buttonText: theme.foreground
    palette.mid: theme.secondary
    palette.highlight: theme.accent
    palette.highlightedText: theme.accentText
    closePolicy: installing ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle {
        color: root.theme.surface
        radius: root.theme.radius
        border.color: root.theme.border
    }
    onOpened: {
        scroll.ScrollBar.vertical.position = 0;
        closeButton.forceActiveFocus(Qt.PopupFocusReason);
    }
    onClosed: clearApproval()
    onUpdateInfoChanged: {
        if (approvalCommit && (updateInfo.phase !== "ready" || approvalCommit !== updateInfo.availableCommit))
            clearApproval();
    }

    function clearApproval() {
        approvalCommit = "";
        approvalVersion = "";
    }
    function begin() {
        if (opened) return;
        clearApproval();
        if (!updater.busy && !updater.error) updater.refresh();
        open();
    }
    function requestDismiss() {
        if (installing) return false;
        close();
        return true;
    }
    function reviewRestart() {
        if (updater.busy || !updater.canApply || updateInfo.phase !== "ready" || !updateInfo.availableCommit) return;
        approvalCommit = updateInfo.availableCommit;
        approvalVersion = updateInfo.availableVersion;
        Qt.callLater(() => cancelRestart.forceActiveFocus(Qt.TabFocusReason));
    }
    function approveRestart() {
        if (!confirmationValid || updater.busy || !updater.canApply) return;
        const commit = approvalCommit;
        clearApproval();
        root.restartRequested(commit);
    }

    component ContributionRow: DButton {
        id: contributionRow
        required property string description
        required property string destination
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.minimumHeight: implicitHeight
        implicitHeight: Math.max(theme.space(56), contributionContent.implicitHeight + topPadding + bottomPadding + 2)
        quiet: true; iconOnly: false
        Accessible.description: description + ". " + qsTr("Opens in your browser.")
        onClicked: Qt.openUrlExternally(destination)
        contentItem: RowLayout {
            id: contributionContent
            spacing: contributionRow.theme.space(12)
            DIcon {
                name: contributionRow.iconName; color: contributionRow.theme.secondary
                Layout.preferredWidth: contributionRow.theme.space(20)
                Layout.preferredHeight: contributionRow.theme.space(20)
            }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0
                spacing: contributionRow.theme.space(2)
                DText {
                    theme: contributionRow.theme; text: contributionRow.text
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                }
                DText {
                    theme: contributionRow.theme; text: contributionRow.description
                    color: contributionRow.theme.secondary; font.pixelSize: contributionRow.theme.small
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                }
            }
            DIcon {
                name: "external"; color: contributionRow.theme.secondary
                Layout.preferredWidth: contributionRow.theme.space(16)
                Layout.preferredHeight: contributionRow.theme.space(16)
            }
        }
    }

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(12)
        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(12)
            DText {
                theme: root.theme; text: qsTr("Settings")
                font.pixelSize: root.theme.title; font.italic: true
                Layout.fillWidth: true; Layout.minimumWidth: 0
            }
            DButton {
                id: closeButton
                theme: root.theme; text: qsTr("Close settings"); iconName: "close"; quiet: true
                objectName: "settingsClose"; enabled: !root.installing
                onClicked: root.requestDismiss()
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            Layout.preferredHeight: sections.implicitHeight + padding * 2
            contentWidth: availableWidth
            padding: root.theme.space(3)
            clip: true
            focusPolicy: Qt.StrongFocus
            Accessible.name: qsTr("Settings sections")
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            background: Rectangle {
                color: "transparent"; radius: root.theme.radius
                border.color: root.theme.accent; border.width: scroll.visualFocus ? 1 : 0
            }
            Keys.onPressed: event => {
                if (event.key !== Qt.Key_PageDown && event.key !== Qt.Key_PageUp) return;
                const direction = event.key === Qt.Key_PageDown ? 1 : -1;
                const bar = scroll.ScrollBar.vertical;
                bar.position = Math.max(0, Math.min(1 - bar.size, bar.position + direction * bar.size));
                event.accepted = true;
            }
            ColumnLayout {
                id: sections
                width: scroll.availableWidth
                spacing: root.theme.space(12)
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: qsTr("General"); color: root.theme.secondary; font.bold: true; Layout.fillWidth: true }
                    GridLayout {
                        id: openingRow
                        Layout.fillWidth: true
                        columns: width < root.theme.space(400) ? 1 : 2
                        columnSpacing: root.theme.space(16); rowSpacing: root.theme.space(6)
                        DText { theme: root.theme; text: qsTr("Opening page"); Layout.fillWidth: true }
                        DComboBox {
                            theme: root.theme; objectName: "settingsOpeningPage"
                            Layout.fillWidth: openingRow.columns === 1
                            Layout.preferredWidth: root.theme.space(190)
                            model: [qsTr("Timer"), qsTr("Today"), qsTr("Last used")]
                            acknowledgedIndex: ["Timer", "Today", "last"].indexOf(root.preferences.openingPage)
                            enabled: root.preferencesEditable
                            Accessible.name: qsTr("Opening page")
                            onSelectionRequested: index => root.preferences.setValue("openingPage", ["Timer", "Today", "last"][index])
                        }
                    }
                    DSwitch {
                        theme: root.theme; objectName: "settingsTimerSound"; Layout.fillWidth: true
                        text: qsTr("Timer sound")
                        value: !root.countdown.muted
                        enabled: root.countdown.loaded && !root.countdown.busy && !root.countdown.error
                        onToggleRequested: root.countdown.toggleMute()
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                        font.pixelSize: root.theme.small
                        visible: !root.countdown.loaded && !root.countdown.error
                        text: qsTr("Loading Timer…")
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: root.theme.space(6)
                        visible: root.countdown.error !== ""
                        DText {
                            theme: root.theme; text: root.countdown.error; color: root.theme.urgent
                            Layout.fillWidth: true; font.pixelSize: root.theme.small; wrapMode: Text.Wrap
                        }
                        DButton {
                            theme: root.theme; text: qsTr("Retry Timer"); iconName: "retry"; iconOnly: false
                            enabled: !root.countdown.busy; onClicked: root.countdown.retry()
                        }
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                        font.pixelSize: root.theme.small
                        visible: !root.preferences.loaded && !root.preferences.error
                        text: qsTr("Loading settings…")
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: root.theme.space(6)
                        visible: root.preferences.error !== ""
                        DText {
                            theme: root.theme; text: root.preferences.error; color: root.theme.urgent
                            Layout.fillWidth: true; font.pixelSize: root.theme.small; wrapMode: Text.Wrap
                        }
                        DButton {
                            theme: root.theme; text: qsTr("Retry settings"); iconName: "retry"; iconOnly: false
                            enabled: !root.preferences.busy; onClicked: root.preferences.retry()
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    DText { theme: root.theme; text: qsTr("Privacy"); color: root.theme.secondary; font.bold: true; Layout.fillWidth: true }
                    DSwitch {
                        theme: root.theme; objectName: "settingsOnlineQuotes"; Layout.fillWidth: true
                        text: qsTr("Online quotes")
                        helpText: qsTr("When off, use the 1,000 quotes included with Daymark.")
                        value: root.preferences.onlineQuotes
                        enabled: root.preferencesEditable
                        onToggleRequested: value => root.preferences.setValue("onlineQuotes", value)
                    }
                    GridLayout {
                        id: idleRow
                        Layout.fillWidth: true
                        columns: width < root.theme.space(400) ? 1 : 2
                        columnSpacing: root.theme.space(16); rowSpacing: root.theme.space(6)
                        DText { theme: root.theme; text: qsTr("Diary inactivity lock"); Layout.fillWidth: true }
                        DComboBox {
                            theme: root.theme; objectName: "settingsDiaryIdle"
                            Layout.fillWidth: idleRow.columns === 1
                            Layout.preferredWidth: root.theme.space(190)
                            model: [qsTr("Off"), qsTr("1 minute"), qsTr("5 minutes"), qsTr("15 minutes")]
                            acknowledgedIndex: [0, 1, 5, 15].indexOf(root.preferences.diaryIdleMinutes)
                            enabled: root.preferencesEditable
                            Accessible.name: qsTr("Diary inactivity lock")
                            Accessible.description: qsTr("Existing Diary focus, hide and navigation locks always stay on.")
                            onSelectionRequested: index => root.preferences.setValue("diaryIdleMinutes", [0, 1, 5, 15][index])
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                DButton {
                    id: calendarsAction
                    theme: root.theme; objectName: "settingsCalendars"
                    text: qsTr("Calendars"); iconName: "calendar"; iconOnly: false; quiet: true
                    Layout.fillWidth: true
                    leftPadding: 0; rightPadding: 0
                    enabled: !root.installing
                    onClicked: root.calendarsRequested()
                    contentItem: RowLayout {
                        spacing: root.theme.space(12)
                        DIcon {
                            name: "calendar"; color: root.theme.foreground
                            Layout.preferredWidth: root.theme.space(22); Layout.preferredHeight: root.theme.space(22)
                        }
                        DText { theme: root.theme; text: calendarsAction.text; Layout.fillWidth: true }
                        DIcon {
                            name: "next"; color: root.theme.secondary
                            Layout.preferredWidth: root.theme.space(18); Layout.preferredHeight: root.theme.space(18)
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                DButton {
                    id: dataSafetyAction
                    theme: root.theme; objectName: "settingsDataSafety"
                    text: qsTr("Data & Safety"); iconName: "shield"; iconOnly: false; quiet: true
                    Layout.fillWidth: true
                    leftPadding: 0; rightPadding: 0
                    enabled: !root.installing
                    onClicked: root.dataRequested()
                    contentItem: RowLayout {
                        spacing: root.theme.space(12)
                        DIcon {
                            name: "shield"; color: root.theme.foreground
                            Layout.preferredWidth: root.theme.space(22); Layout.preferredHeight: root.theme.space(22)
                        }
                        DText { theme: root.theme; text: dataSafetyAction.text; Layout.fillWidth: true }
                        DIcon {
                            name: "next"; color: root.theme.secondary
                            Layout.preferredWidth: root.theme.space(18); Layout.preferredHeight: root.theme.space(18)
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    RowLayout {
                        id: updateHeading
                        Layout.fillWidth: true; spacing: root.theme.space(10)
                        DText {
                            theme: root.theme; text: qsTr("Updates")
                            color: root.theme.secondary; font.bold: true
                            Layout.minimumWidth: 0
                        }
                        DText {
                            theme: root.theme; color: root.theme.secondary
                            font.pixelSize: root.theme.small
                            text: root.updateInfo.installedVersion ? "v" + root.updateInfo.installedVersion : ""
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            elide: Text.ElideRight; wrapMode: Text.NoWrap
                        }
                        DButton {
                            id: checkUpdate
                            Layout.preferredWidth: Math.min(root.theme.space(190), root.availableWidth * 0.48)
                            theme: root.theme; objectName: "settingsCheckUpdate"
                            text: updateHeading.width < root.theme.space(400) ? qsTr("Check") : qsTr("Check & update")
                            iconName: "update"
                            iconOnly: false
                            Accessible.name: qsTr("Check & update")
                            Accessible.description: root.updateInfo.message || ""
                            enabled: !root.updater.busy && !root.installing
                            onClicked: { root.clearApproval(); root.updater.check(); }
                            background: Rectangle {
                                radius: root.theme.radius
                                color: checkUpdate.down ? root.theme.fill("pressed")
                                    : checkUpdate.hovered || checkUpdate.visualFocus ? root.theme.fill("hover-cursor") : "transparent"
                                border.color: root.theme.accent
                                border.width: checkUpdate.visualFocus ? Math.max(2, root.theme.strokeWidth("focus")) : 1
                            }
                        }
                    }
                    DSwitch {
                        theme: root.theme; objectName: "settingsAutomaticUpdates"; Layout.fillWidth: true
                        text: qsTr("Automatic updates")
                        description: qsTr("Every 24 hours")
                        helpText: qsTr("Check every 24 hours. Updating always asks before restarting the whole desktop shell.")
                        value: root.preferences.automaticUpdates
                        enabled: root.preferencesEditable
                        onToggleRequested: value => root.preferences.setValue("automaticUpdates", value)
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                        font.pixelSize: root.theme.small; visible: root.updater.busy
                        text: root.installing ? qsTr("Updating Daymark…") : qsTr("Checking…")
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                        color: root.updater.error ? root.theme.urgent : root.theme.secondary
                        text: root.updater.error || root.updateInfo.message || ""
                        visible: text !== "" && (!!root.updater.error || root.updateInfo.lastAttemptAt > 0)
                        wrapMode: Text.Wrap
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                        visible: root.updateInfo.phase === "ready"
                        text: qsTr("%1 is available. Installing it requires restarting the whole desktop shell.").arg(root.updateInfo.availableVersion || qsTr("An update"))
                    }
                    DText {
                        theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                        color: root.theme.secondary; text: root.updater.blockReason || ""
                        visible: root.updateInfo.phase === "ready" && !root.updater.canApply && text !== ""
                        wrapMode: Text.Wrap
                    }
                    DButton {
                        theme: root.theme; objectName: "settingsReviewUpdate"
                        text: qsTr("Review update"); iconName: "update"; iconOnly: false
                        visible: root.updateInfo.phase === "ready" && !root.confirmationValid
                        enabled: root.updater.canApply && !root.updater.busy
                        onClicked: root.reviewRestart()
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: approvalBody.implicitHeight + root.theme.space(24)
                        visible: root.confirmationValid
                        color: root.theme.accentSurface; radius: root.theme.radius; border.color: root.theme.accent
                        ColumnLayout {
                            id: approvalBody
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: root.theme.space(12)
                            spacing: root.theme.space(8)
                            DText {
                                theme: root.theme; Layout.fillWidth: true; font.bold: true
                                text: qsTr("Restart shell & update?")
                            }
                            DText {
                                theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                                text: qsTr("This restarts the whole desktop shell, interrupting the bar and all shell plugins, not only Daymark. Save your work first. Your external Daymark data stays in place.")
                            }
                            DText {
                                theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                                color: root.theme.secondary; wrapMode: Text.WrapAnywhere
                                text: qsTr("Version: %1\nCommit: %2").arg(root.approvalVersion).arg(root.approvalCommit)
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: root.theme.space(8)
                                DButton {
                                    id: cancelRestart
                                    theme: root.theme; text: qsTr("Cancel"); objectName: "settingsCancelRestart"
                                    onClicked: { root.clearApproval(); closeButton.forceActiveFocus(Qt.TabFocusReason); }
                                }
                                DButton {
                                    id: approveButton
                                    theme: root.theme; text: qsTr("Restart shell & update"); objectName: "settingsApproveRestart"
                                    width: Math.min(implicitWidth, parent.width)
                                    primary: true
                                    contentItem: DText {
                                        theme: root.theme; text: approveButton.text
                                        font.bold: true
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    enabled: root.confirmationValid && root.updater.canApply && !root.updater.busy
                                    onClicked: root.approveRestart()
                                }
                            }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    text: qsTr("Last checked: %1").arg(root.updateInfo.lastCheckedAt
                        ? new Date(root.updateInfo.lastCheckedAt).toLocaleString(Qt.locale(), Locale.ShortFormat)
                        : qsTr("Never"))
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: contributionBody.implicitHeight + root.theme.space(24)
                    color: root.theme.controlSurface
                    border.color: root.theme.border
                    radius: root.theme.radius
                    ColumnLayout {
                        id: contributionBody
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: root.theme.space(12)
                        spacing: root.theme.space(4)
                        DText {
                            theme: root.theme; text: qsTr("CONTRIBUTION")
                            color: root.theme.secondary; font.pixelSize: root.theme.small
                            font.letterSpacing: root.theme.space(2)
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                        }
                        ContributionRow {
                            theme: root.theme; objectName: "settingsReportBug"
                            text: qsTr("Report a bug"); description: qsTr("Something broken? Tell us here")
                            iconName: "bug"
                            destination: "https://github.com/naolselemon/daymark/issues/new?title=Bug%20report"
                        }
                        ContributionRow {
                            theme: root.theme; objectName: "settingsShareIdea"
                            text: qsTr("Share an idea"); description: qsTr("A feature you wish existed")
                            iconName: "idea"
                            destination: "https://github.com/naolselemon/daymark/issues/new?title=Feature%20idea"
                        }
                        ContributionRow {
                            theme: root.theme; objectName: "settingsContribute"
                            text: qsTr("Contribute"); description: qsTr("Pull requests welcome")
                            iconName: "contribute"
                            destination: "https://github.com/naolselemon/daymark/pulls"
                        }
                        ContributionRow {
                            theme: root.theme; objectName: "settingsMarketplaceLike"
                            text: qsTr("Please leave a like"); description: qsTr("A like on the marketplace keeps it going")
                            iconName: "heart"
                            destination: "https://plugins.omarchy.org/plugin.html?id=naolselemon.daymark"
                        }
                        ContributionRow {
                            theme: root.theme; objectName: "settingsGitHubStar"
                            text: qsTr("Star on GitHub"); description: qsTr("Support the repository")
                            iconName: "star"
                            destination: "https://github.com/naolselemon/daymark"
                        }
                    }
                }
                Rectangle {
                    objectName: "settingsDangerZone"
                    Layout.fillWidth: true
                    implicitHeight: dangerBody.implicitHeight + root.theme.space(24)
                    color: "transparent"; radius: root.theme.radius; border.color: root.theme.urgent
                    ColumnLayout {
                        id: dangerBody
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: root.theme.space(12)
                        spacing: root.theme.space(12)
                        DText {
                            theme: root.theme; text: qsTr("DANGER ZONE")
                            color: root.theme.urgent; font.pixelSize: root.theme.small
                            font.letterSpacing: root.theme.space(2); Layout.fillWidth: true
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: root.theme.space(12)
                            ColumnLayout {
                                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                                DText { theme: root.theme; text: qsTr("Reset today"); Layout.fillWidth: true }
                                DText {
                                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                                    font.pixelSize: root.theme.small
                                    text: qsTr("Only today's entries. Plans and completion states are kept.")
                                }
                            }
                            DButton {
                                theme: root.theme; objectName: "settingsResetToday"; text: qsTr("Reset today")
                                enabled: !root.installing && !root.cleanupBlockReason
                                Accessible.description: qsTr("Review permanent deletion of today's activity entries. Requires confirmation and your system password.")
                                onClicked: root.cleanupRequested("reset_today_entries")
                            }
                        }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.urgent; opacity: 0.3 }
                        RowLayout {
                            Layout.fillWidth: true; spacing: root.theme.space(12)
                            ColumnLayout {
                                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(2)
                                DText { theme: root.theme; text: qsTr("Wipe all activity data"); Layout.fillWidth: true }
                                DText {
                                    theme: root.theme; Layout.fillWidth: true; color: root.theme.urgent
                                    font.pixelSize: root.theme.small
                                    text: qsTr("All activity data. Diary is kept.\nCannot be undone.")
                                }
                            }
                            DButton {
                                theme: root.theme; objectName: "settingsWipeAll"; text: qsTr("Wipe all")
                                Accessible.name: qsTr("Wipe all activity data")
                                enabled: !root.installing && !root.cleanupBlockReason
                                Accessible.description: qsTr("Review permanent deletion of all activity data. Requires typed confirmation and your system password.")
                                onClicked: root.cleanupRequested("wipe_activity_data")
                            }
                        }
                        DText {
                            theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small
                            color: root.theme.urgent; text: root.cleanupBlockReason; visible: text !== ""
                        }
                    }
                }
                Rectangle {
                    objectName: "settingsAbout"
                    Layout.fillWidth: true
                    implicitHeight: aboutBody.implicitHeight + root.theme.space(32)
                    color: root.theme.controlSurface; radius: root.theme.radius
                    ColumnLayout {
                        id: aboutBody
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: root.theme.space(16)
                        spacing: root.theme.space(10)
                        DaymarkMark {
                            ink: root.theme.foreground; accent: root.theme.accent
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: root.theme.space(40); Layout.preferredHeight: root.theme.space(40)
                        }
                        DText {
                            theme: root.theme; text: "Daymark"; font.pixelSize: root.theme.heading; font.bold: true
                            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                        }
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter
                            implicitWidth: aboutVersion.implicitWidth + root.theme.space(16)
                            implicitHeight: aboutVersion.implicitHeight + root.theme.space(6)
                            color: "transparent"; border.color: root.theme.accent; radius: root.theme.radius
                            DText {
                                id: aboutVersion
                                theme: root.theme; objectName: "settingsAboutVersion"
                                anchors.centerIn: parent
                                text: root.updateInfo.installedVersion
                                    ? "v" + root.updateInfo.installedVersion.replace(/^v/, "") : qsTr("Version unavailable")
                                color: root.theme.accent; font.pixelSize: root.theme.small
                            }
                        }
                        DText {
                            theme: root.theme; text: qsTr("Give your day a shape. Keep what mattered.")
                            font.italic: true; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                        }
                        DText {
                            theme: root.theme; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                            color: root.theme.secondary; font.pixelSize: root.theme.small
                            text: qsTr("Local-first planner, timer and diary\nNo accounts · No telemetry")
                        }
                    }
                }
            }
        }
    }
}
