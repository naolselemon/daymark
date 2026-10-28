import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property string name: ""
    required property color color
    implicitWidth: 24
    implicitHeight: 24
    Accessible.ignored: true

    // Explicit semantic names keep artwork independent of translated labels.
    readonly property string drawing: {
        switch (name) {
        case "add": return "M12 5 V19 M5 12 H19";
        case "log": return "M14 4 H5 V20 H19 V13 M8 9 H11 M8 13 H10 M13 12 L20 5 L22 7 L15 14 L12 15 Z";
        case "edit": return "M4 20 L5 15 L17 3 L21 7 L9 19 Z M14 6 L18 10 M5 15 L9 19";
        case "save": return "M4 3 H17 L21 7 V21 H3 V3 Z M7 3 V9 H16 V3 M7 21 V14 H17 V21";
        case "pin": return "M9 3 H17 L15 9 L19 13 V15 H5 V13 L9 9 Z M12 15 V22";
        case "unpin": return "M9 3 H17 L15 9 L19 13 V15 H11 M9 9 L5 13 V15 H7 M12 17 V22 M3 3 L21 21";
        case "lock": return "M7 10 V7 A5 5 0 0 1 17 7 V10 M5 10 H19 V21 H5 Z M12 14 V17";
        case "unlock": return "M7 10 V7 A5 5 0 0 1 16.5 5 M5 10 H19 V21 H5 Z M12 14 V17";
        case "diary": return "M3 5 Q7 3 12 6 Q17 3 21 5 V20 Q17 18 12 21 Q7 18 3 20 Z M12 6 V21 M6 9 L9 10 M15 10 L18 9";
        case "calendar": return "M4 5 H20 V21 H4 Z M4 10 H20 M8 3 V7 M16 3 V7 M8 14 H10 M14 14 H16 M8 18 H10";
        case "today": return "M4 5 H20 V21 H4 Z M4 10 H20 M8 3 V7 M16 3 V7 M9 15 L11 17 L16 13";
        case "plan": return "M8 4 H20 V21 H4 V4 H8 M9 2 H15 V6 H9 Z M8 11 H16 M8 15 H16 M8 18 H13";
        case "search": return "M16 10 A6 6 0 1 1 4 10 A6 6 0 1 1 16 10 M15 15 L21 21";
        case "export": return "M12 15 V3 M8 7 L12 3 L16 7 M4 13 V21 H20 V13";
        case "import": return "M12 3 V15 M8 11 L12 15 L16 11 M4 13 V21 H20 V13";
        case "backspace": return "M8 5 H22 V19 H8 L2 12 Z M12 9 L18 15 M18 9 L12 15";
        case "previous":
        case "back": return "M15 5 L8 12 L15 19";
        case "next": return "M9 5 L16 12 L9 19";
        case "close": return "M6 6 L18 18 M18 6 L6 18";
        case "undo":
        case "restore": return "M8 4 L3 9 L8 14 M3 9 H14 A6 6 0 0 1 14 21 H10";
        case "delete": return "M4 6 H20 M9 6 V3 H15 V6 M6 6 L7 21 H17 L18 6 M10 10 V17 M14 10 V17";
        case "settings": return "M9 3 H15 L15.5 6 L17 7 L20 6 L23 11 L20.5 13 L20 15 L21 18 L16 21 L14 18.5 H10 L8 21 L3 18 L4 15 L3.5 13 L1 11 L4 6 L7 7 L8.5 6 Z M15.5 12 A3.5 3.5 0 1 1 8.5 12 A3.5 3.5 0 1 1 15.5 12";
        case "update": return "M20 10 A8 8 0 0 0 6 5 L3 8 M3 3 V8 H8 M4 14 A8 8 0 0 0 18 19 L21 16 M16 16 H21 V21";
        case "shield": return "M12 3 L21 6 V12 Q20 18 12 22 Q4 18 3 12 V6 Z M8 12 L11 15 L16 9";
        case "keyboard": return "M2 5 H22 V19 H2 Z M6 9 H7 M11 9 H12 M16 9 H18 M6 12 H7 M11 12 H12 M16 12 H18 M7 16 H17";
        case "timer": return "M9 2 H15 M12 2 V5 M18 5 L20 7 M20 14 A8 8 0 1 1 4 14 A8 8 0 1 1 20 14 M12 9 V14 L15 16";
        case "history": return "M4 9 A9 9 0 1 1 4 17 M3 3 V9 H9 M12 7 V12 L16 14";
        case "play": return "M7 4 L21 12 L7 20 Z";
        case "pause": return "M6 4 H9 V20 H6 Z M15 4 H18 V20 H15 Z";
        case "retry":
        case "reset": return "M4 9 A9 9 0 1 1 4 17 M3 3 V9 H9";
        case "mute": return "M3 9 H7 L12 5 V19 L7 15 H3 Z M16 9 L22 15 M22 9 L16 15";
        case "sound": return "M3 9 H7 L12 5 V19 L7 15 H3 Z M16 8 Q20 12 16 16 M19 5 Q25 12 19 19";
        case "check": return "M4 12 L9 17 L20 6";
        case "pages": return "M8 3 H21 V17 H8 Z M4 7 V21 H17 M12 7 H17 M12 11 H17";
        case "expand": return "M5 9 L12 16 L19 9";
        case "collapse": return "M5 15 L12 8 L19 15";
        default: return "";
        }
    }

    Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: Math.min(root.width, root.height) / 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.color
            strokeWidth: 1.8
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.drawing }
        }
    }
}
