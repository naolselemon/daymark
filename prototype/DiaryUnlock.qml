pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    required property var authenticator
    property string purpose: "Unlock your diary"
    readonly property bool busy: !!authenticator && authenticator.busy
    signal cancelled()
    objectName: "diaryUnlockDialog"
    anchors.centerIn: parent
    width: Math.min(parent.width - theme.space(32), theme.space(460))
    onBusyChanged: if (opened && !busy) password.forceActiveFocus(Qt.PopupFocusReason)
    height: Math.min(parent.height - theme.space(32), implicitHeight)
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(28)
    modal: true; focus: true; z: 20
    closePolicy: Popup.CloseOnEscape
    background: Rectangle { color: root.theme.background; radius: root.theme.radius; border.color: root.theme.border }

    function begin(title) {
        if (authenticator) authenticator.cancel();
        purpose = title;
        password.clear();
        open();
        password.forceActiveFocus(Qt.PopupFocusReason);
    }
    function submit() {
        if (!authenticator || busy || !password.text) return;
        let value = password.text;
        password.clear();
        authenticator.authenticate(value);
        value = "";
    }
    onClosed: { password.clear(); cancelled(); }
    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(20)
        DText {
            theme: root.theme; text: root.purpose
            font.pixelSize: root.theme.title; font.bold: true; Layout.fillWidth: true
        }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.preferredHeight: fields.implicitHeight
            Layout.minimumHeight: root.theme.space(100)
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: fields
                width: parent.width
                spacing: root.theme.space(16)
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                    text: "Verify with your Linux account password. Daymark does not save your password."
                }
                DField {
                    id: password
                    objectName: "diaryPassword"
                    theme: root.theme; Layout.fillWidth: true
                    placeholderText: "System password"
                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    enabled: !!root.authenticator && !root.busy
                    onAccepted: root.submit()
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.urgent
                    objectName: "diaryAuthError"
                    text: !root.authenticator
                        ? "System-password unlocking requires the native Omarchy shell. This standalone preview remains locked."
                        : root.authenticator.errorMessage
                    visible: text !== ""
                    Accessible.role: Accessible.AlertMessage
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    text: "The diary locks again when you leave it or switch away from Daymark."
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            DButton { theme: root.theme; quiet: true; text: "Cancel"; objectName: "diaryUnlockCancel"; onClicked: root.close() }
            Item { Layout.fillWidth: true }
            DButton {
                theme: root.theme; primary: true
                objectName: "diaryUnlockSubmit"
                text: root.busy ? "Verifying…" : "Unlock"
                enabled: !!root.authenticator && !root.busy && password.text.length > 0
                onClicked: root.submit()
            }
        }
    }
}
