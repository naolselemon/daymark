pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic

Item {
    id: root
    objectName: "quoteView"
    required property var theme
    property bool active: false
    property bool onlineEnabled: true
    property alias controller: quoteController

    QuoteController {
        id: quoteController
        active: root.active
        onlineEnabled: root.onlineEnabled
    }

    DText {
        id: heading
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.margins: root.theme.space(4)
        theme: root.theme; text: qsTr("A moment to reflect")
        font.pixelSize: root.theme.small; color: root.theme.secondary
    }
    Rectangle {
        id: divider
        anchors.top: heading.bottom; anchors.left: parent.left; anchors.right: parent.right
        anchors.topMargin: root.theme.space(8)
        height: 1; color: root.theme.border
    }
    ScrollView {
        id: quoteScroll
        objectName: "quoteScroll"
        anchors.top: divider.bottom; anchors.bottom: parent.bottom
        anchors.left: parent.left; anchors.right: parent.right
        contentWidth: availableWidth
        contentHeight: quoteCanvas.implicitHeight
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Item {
            id: quoteCanvas
            width: quoteScroll.availableWidth
            height: implicitHeight
            implicitHeight: Math.max(quoteScroll.availableHeight, quoteGroup.implicitHeight + root.theme.space(32))

            Column {
                id: quoteGroup
                anchors.centerIn: parent
                width: Math.max(0, Math.min(parent.width - root.theme.space(24), root.theme.space(600)))
                spacing: root.theme.space(16)

                DText {
                    objectName: "quoteText"
                    theme: root.theme
                    width: parent.width
                    text: quoteController.quote
                    textFormat: Text.PlainText
                    font.pixelSize: Math.round(root.theme.heading
                        * Math.max(1, Math.min(1.35, width / root.theme.space(420))))
                    font.italic: true
                    lineHeight: 1.35
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }

                DText {
                    objectName: "quoteAuthor"
                    theme: root.theme
                    width: parent.width
                    text: quoteController.author
                    textFormat: Text.PlainText
                    color: root.theme.secondary
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }

                DText {
                    id: attribution
                    objectName: "quoteAttribution"
                    readonly property bool provider: quoteController.source === "zenquotes"
                    theme: root.theme
                    width: parent.width
                    text: provider ? "Quotes provided by ZenQuotes" : "Daymark original collection"
                    textFormat: Text.PlainText
                    font.pixelSize: root.theme.small
                    font.underline: provider
                    color: activeFocus ? root.theme.accent : root.theme.secondary
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    activeFocusOnTab: provider && root.active
                    Accessible.role: provider ? Accessible.Link : Accessible.StaticText
                    Accessible.name: text
                    Accessible.description: provider ? "Open zenquotes.io in your browser" : "Original reflections written for Daymark"
                    Accessible.focusable: provider && root.active
                    Accessible.onPressAction: openProvider()

                    function openProvider() {
                        if (provider && root.active) Qt.openUrlExternally("https://zenquotes.io/");
                    }

                    Keys.onPressed: event => {
                        if (provider && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) {
                            openProvider();
                            event.accepted = true;
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: attribution.provider && root.active
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            attribution.forceActiveFocus(Qt.MouseFocusReason);
                            attribution.openProvider();
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: quoteController
        function onQuoteChanged() {
            const flickable = quoteScroll.contentItem as Flickable;
            if (flickable) flickable.contentY = 0;
        }
    }
}
