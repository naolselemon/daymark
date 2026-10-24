import QtQuick
import QtQuick.Shapes

// Original brush-like silhouette: an open page, a rising day, and a pen stroke.
Item {
    id: root
    required property color ink
    required property color accent
    property bool compact: false
    implicitWidth: 32
    implicitHeight: 32
    Accessible.ignored: true

    Shape {
        anchors.centerIn: parent
        width: 32
        height: 32
        scale: Math.min(root.width, root.height) / 32
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: root.ink
            strokeColor: "transparent"
            PathSvg {
                path: "M2.7 12.2 C6.4 10.8 10.9 11.9 15.2 14 L15.8 27.8 C11.4 25.1 6.6 24.4 2.8 25.4 L2.7 12.2 Z M5 14.3 L4.8 23 C8.1 22.8 10.8 23.6 13.5 24.9 L13.1 15.6 C10.5 14.4 7.8 13.9 5 14.3 Z M16.7 14.1 C20.5 11.8 25 11.4 28.7 12.4 L28.3 25.2 C24.4 24.5 20.6 25.4 16 28 L16.7 14.1 Z M18.5 15.5 L18 24.7 C20.8 23.4 23.5 22.9 26.3 23 L26.7 14.3 C23.7 13.9 21.1 14.3 18.5 15.5 Z"
            }
        }
        ShapePath {
            fillColor: root.accent
            strokeColor: "transparent"
            PathSvg {
                path: "M10.2 10.7 C10.6 3.6 21.3 3.4 22 10.6 C18.7 10 13.9 10 10.2 10.7 Z M19.5 19.1 C20 18.6 20.4 18.6 20.8 19.1 L22 20.2 C24 17.5 26.6 14.8 30 12.5 C28 16.3 25.6 19.3 22.6 23 C22.3 23.4 21.7 23.4 21.3 22.9 L19.2 20.1 C19 19.7 19.2 19.4 19.5 19.1 Z"
            }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.accent
            strokeWidth: 1.6
            capStyle: ShapePath.RoundCap
            PathSvg { path: root.compact ? "M16 1.8 L16.1 2.7" : "M16 1.5 L16.1 2.6 M6.8 5.3 L8.2 6.5 M24.2 6.4 L25.6 5.1" }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.ink
            strokeWidth: 1.15
            capStyle: ShapePath.RoundCap
            PathSvg { path: root.compact ? "" : "M6.8 17.6 Q9.1 17.5 11 18.5 M6.8 20.3 Q8.5 20.4 10.2 21" }
        }
    }
}
