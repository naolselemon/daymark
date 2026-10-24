import QtQuick
import QtQuick.Shapes

// Option A: five radial segments, a visual identity rather than a feature count.
Item {
    id: root
    required property color ink
    required property color accent
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
                path: "M24.973 5.421 L29.000 17.816 L21.613 16.167 L19.965 11.097 Z M28.062 20.703 L17.518 28.364 L16.803 20.829 L21.116 17.695 Z M14.482 28.364 L3.938 20.703 L10.884 17.695 L15.197 20.829 Z M3.000 17.816 L7.027 5.421 L12.035 11.097 L10.387 16.167 Z"
            }
        }
        ShapePath {
            fillColor: root.accent
            strokeColor: "transparent"
            PathSvg {
                path: "M9.484 3.636 L22.516 3.636 L18.666 10.153 L13.334 10.153 Z"
            }
        }
    }
}
