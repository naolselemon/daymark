import QtQuick
import QtMultimedia

// Loaded separately: missing multimedia support must never disable countdowns.
Item {
    id: root
    readonly property bool ready: chime.status === SoundEffect.Ready && devices.audioOutputs.length > 0
    readonly property string error: chime.status === SoundEffect.Error || devices.audioOutputs.length === 0
        ? "Completion sound unavailable; the timer still works." : ""
    function play() { if (ready) chime.play(); }
    MediaDevices { id: devices }
    SoundEffect {
        id: chime
        source: Qt.resolvedUrl("countdown-chime.wav")
        loops: 1
    }
}
