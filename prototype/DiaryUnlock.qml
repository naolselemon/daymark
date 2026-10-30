pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    required property var authenticator
    property string purpose: "Unlock your diary"
    property bool authorizationOnly: false
    readonly property bool busy: !!authenticator && authenticator.busy
    signal cancelled()
    objectName: "diaryUnlockDialog"
    x: 0; y: 0
    width: parent ? parent.width : 0
    onBusyChanged: if (opened && !busy) password.forceActiveFocus(Qt.PopupFocusReason)
    height: parent ? parent.height : 0
    padding: theme.space(16)
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
        spacing: root.theme.space(12)
        RowLayout {
            Layout.fillWidth: true; spacing: root.theme.space(8)
            DButton {
                theme: root.theme; text: qsTr("Back"); iconName: "back"; quiet: true
                objectName: "diaryUnlockCancel"; onClicked: root.close()
            }
            DText {
                theme: root.theme; text: root.purpose
                font.pixelSize: root.theme.heading; font.bold: true
                Layout.fillWidth: true; Layout.minimumWidth: 0
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        ScrollView {
            id: authScroll
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.preferredHeight: fields.implicitHeight
            Layout.minimumHeight: 0
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: fields
                width: authScroll.availableWidth
                spacing: root.theme.space(12)
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
                        ? (root.authorizationOnly
                            ? qsTr("System-password verification requires the native Omarchy shell. This standalone preview cannot authorize this action.")
                            : "System-password unlocking requires the native Omarchy shell. This standalone preview remains locked.")
                        : root.authenticator.errorMessage
                    visible: text !== ""
                    Accessible.role: Accessible.AlertMessage
                }
                DText {
                    theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                    font.pixelSize: root.theme.small
                    text: root.authorizationOnly
                        ? qsTr("This verification authorizes only the action you just confirmed. Your Diary stays locked.")
                        : "The diary locks again when you leave it or switch away from Daymark."
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            DButton {
                theme: root.theme; primary: true
                objectName: "diaryUnlockSubmit"
                text: root.busy ? qsTr("Verifying…") : root.authorizationOnly ? qsTr("Verify") : qsTr("Unlock")
                iconName: "unlock"
                enabled: !!root.authenticator && !root.busy && password.text.length > 0
                onClicked: root.submit()
            }
        }
    }
}
