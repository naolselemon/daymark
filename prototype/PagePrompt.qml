import QtQuick
import QtQuick.Window
import "PagePrompts.js" as Prompts

Item {
    id: root
    required property var theme
    required property string page
    property bool active: visible && !!Window.window && Window.window.visible
    property int pixelSize: theme.pageTitle
    property bool bold: true
    property string prompt: ""
    property int revealed: 0
    property var previous: ({})
    property bool initialized: false
    readonly property string displayedText: prompt.slice(0, revealed)
    implicitWidth: theme.space(240)
    implicitHeight: measure.implicitHeight
    Accessible.role: Accessible.StaticText
    Accessible.name: prompt

    function begin() {
        typing.stop();
        if (!initialized || !active) return;
        const pool = Prompts.pages[page];
        if (!pool || !pool.length) { prompt = ""; revealed = 0; return; }
        const last = previous[page];
        let index = Math.floor(Math.random() * (pool.length - (last === undefined ? 0 : 1)));
        if (last !== undefined && index >= last) ++index;
        previous[page] = index;
        prompt = pool[index];
        revealed = 0;
        typing.start();
    }
    onActiveChanged: { if (active) begin(); else typing.stop(); }
    onPageChanged: begin()
    Component.onCompleted: { initialized = true; begin(); }

    // Measure the full sentence, not the animated prefix: typing never moves controls.
    DText {
        id: measure
        theme: root.theme; width: parent.width
        text: root.prompt; visible: false
        font.pixelSize: root.pixelSize; font.bold: root.bold; font.italic: true
        wrapMode: Text.Wrap
        Accessible.ignored: true
    }
    DText {
        objectName: "pagePromptText"
        theme: root.theme; anchors.fill: parent
        text: root.displayedText
        font.pixelSize: root.pixelSize; font.bold: root.bold; font.italic: true
        wrapMode: Text.Wrap
        Accessible.ignored: true
    }
    Timer {
        id: typing
        interval: 25; repeat: true
        onTriggered: {
            root.revealed = Math.min(root.prompt.length, root.revealed + 1);
            if (root.revealed === root.prompt.length) stop();
        }
    }
}
