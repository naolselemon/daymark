import QtQuick
import QtQuick.Window
import QtTest
import "../prototype" as Daymark
import "../prototype/PagePrompts.js" as Prompts

TestCase {
    id: testCase
    name: "PagePromptBehavior"
    when: windowShown
    visible: true
    width: 640; height: 480
    QtObject {
        id: fixtureTheme
        property string foreground: "#eeeeee"
        property string family: "sans-serif"
        property int pageTitle: 24
        property int body: 16
        function space(value) { return value; }
    }
    Component {
        id: factory
        Daymark.PagePrompt { theme: fixtureTheme; page: "Timer"; width: 280; active: false }
    }
    function test_animation_reserves_final_height_and_settles() {
        const heading = createTemporaryObject(factory, testCase);
        heading.active = true;
        const target = heading.prompt;
        verify(Prompts.pages.Timer.indexOf(target) >= 0);
        const fullHeight = heading.implicitHeight;
        verify(fullHeight > 0);
        tryVerify(() => heading.revealed > 0 && heading.revealed < target.length);
        compare(heading.implicitHeight, fullHeight);
        tryCompare(heading, "displayedText", target, 4000);
        compare(heading.implicitHeight, fullHeight);
        wait(100);
        compare(heading.prompt, target);
        compare(heading.displayedText, target);
    }
    function test_navigation_cancels_old_text_and_avoids_immediate_repeat() {
        const heading = createTemporaryObject(factory, testCase);
        heading.active = true;
        const timerPrompt = heading.prompt;
        heading.page = "Plan";
        verify(Prompts.pages.Plan.indexOf(heading.prompt) >= 0);
        compare(heading.revealed, 0);
        heading.active = false;
        const paused = heading.revealed;
        wait(80);
        compare(heading.revealed, paused);
        heading.page = "Timer";
        heading.active = true;
        verify(heading.prompt !== timerPrompt);
        verify(Prompts.pages.Timer.indexOf(heading.prompt) >= 0);
        tryCompare(heading, "displayedText", heading.prompt, 4000);
    }
    function test_resize_preserves_sentence_and_animation_position() {
        const heading = createTemporaryObject(factory, testCase);
        heading.active = true;
        tryVerify(() => heading.revealed > 0);
        const text = heading.prompt;
        const position = heading.revealed;
        heading.width = 120;
        heading.pixelSize = 36;
        compare(heading.prompt, text);
        verify(heading.revealed >= position);
        tryCompare(heading, "displayedText", text, 4000);
        const rendered = findChild(heading, "pagePromptText");
        verify(rendered.paintedWidth <= rendered.width + 1);
        verify(rendered.paintedHeight <= heading.implicitHeight + 1);
    }
}
