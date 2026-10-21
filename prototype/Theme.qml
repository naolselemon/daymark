import QtQuick
import "Palette.js" as Palette

// Preview-only projection of installed Omarchy tokens, supplied by preview.py.
// This is not a qs.Commons substitute and performs no desktop configuration IO.
QtObject {
    id: root
    required property var source
    readonly property color background: source.background
    readonly property color foreground: source.foreground
    readonly property color accent: source.accent
    readonly property color urgent: source.urgent
    readonly property color secondary: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.74)
    readonly property color border: source.states.normal.border
    readonly property color surface: Qt.tint(background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.03))
    readonly property color controlSurface: Qt.tint(background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.065))
    readonly property color accentSurface: Qt.tint(background, Qt.rgba(accent.r, accent.g, accent.b, 0.12))
    readonly property color hintBackground: Palette.luminance(background) < Palette.luminance(foreground) ? background : foreground
    readonly property color hintText: Palette.ink(hintBackground, background, foreground)
    readonly property color accentText: Palette.ink(root.accent, root.background, root.foreground)
    readonly property real radius: source.radius
    readonly property string family: source.family
    readonly property real body: source.font.title
    readonly property real small: source.font.body
    readonly property real heading: source.font.heading
    readonly property real display: source.font.display
    readonly property real title: source.font.display
    readonly property real pageTitle: source.font["display-large"]
    readonly property real gap: source.spacing["control-gap"]
    readonly property real padding: source.spacing["panel-padding"]
    function space(px) { return Math.max(1, Math.round(px * source.scale)); }
    function fill(state) { return source.states[state].fill; }
    function stroke(state) { return source.states[state].border; }
    function strokeWidth(state) { return source.states[state].width; }
}
