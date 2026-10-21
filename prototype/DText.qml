import QtQuick

Text {
    required property var theme
    color: theme.foreground
    font.family: theme.family
    font.pixelSize: theme.body
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
}
