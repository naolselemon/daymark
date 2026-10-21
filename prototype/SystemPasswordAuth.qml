pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Services.Pam

QtObject {
    id: root

    readonly property bool busy: _attempt !== null
    readonly property string errorMessage: _errorMessage
    signal authenticated()

    property var _attempt: null
    property int _generation: 0
    property string _errorMessage: ""

    function authenticate(password) {
        if (busy) return false;
        if (typeof password !== "string" || password.length === 0) {
            _errorMessage = "Enter your system password.";
            return false;
        }
        _errorMessage = "";
        const generation = ++_generation;
        const attempt = _context.createObject(root, {
            generation: generation,
            pendingPassword: password
        }) as PamContext;
        password = "";
        if (!attempt) {
            _errorMessage = "System password authentication is unavailable.";
            return false;
        }
        _attempt = attempt;
        // A caller can cancel synchronously when busy changes.
        if (_attempt !== attempt || _generation !== generation) return false;
        if (!attempt.start()) {
            finish(attempt, "System password authentication could not start.", false);
            return false;
        }
        return true;
    }

    function cancel() {
        ++_generation;
        const attempt = _attempt;
        if (attempt) attempt.pendingPassword = "";
        _attempt = null;
        _errorMessage = "";
        if (attempt) {
            attempt.abort();
            attempt.destroy();
        }
    }

    function finish(attempt, message, accepted) {
        if (_attempt !== attempt || _generation !== attempt.generation) return;
        const generation = attempt.generation;
        attempt.pendingPassword = "";
        _attempt = null;
        attempt.abort();
        attempt.destroy();
        if (_generation !== generation) return;
        _errorMessage = message;
        if (accepted && _generation === generation) authenticated();
    }

    // A separate context per attempt keeps late completion/error signals from
    // an aborted conversation from authenticating a later request.
    property Component _context: Component {
        PamContext {
            id: context
            property int generation: 0
            property string pendingPassword: ""
            property bool passwordSent: false

            config: "omarchy-lock-password"
            configDirectory: "/etc/pam.d"
            // Leave user unset: native PamContext resolves getpwuid_r(getuid()),
            // unlike environment variables, which need not name this account.

            onPamMessage: {
                if (root._attempt !== context || !active || !responseRequired) return;
                // Handle only the final per-message signal. responseRequired
                // may remain true after respond(), so its change signal is not
                // an additional password request.
                if (responseVisible || passwordSent) {
                    root.finish(context, "The system password service requested an unsupported prompt.", false);
                    return;
                }
                passwordSent = true;
                let response = pendingPassword;
                pendingPassword = "";
                respond(response);
                response = "";
            }

            onCompleted: function(result) {
                const accepted = result === PamResult.Success && passwordSent;
                const message = accepted ? ""
                    : result === PamResult.MaxTries
                        ? "System authentication is temporarily locked. Wait before trying again."
                        : result === PamResult.Success
                            ? "The system password service did not request a password."
                            : "Authentication failed. Check your system password or try again later.";
                root.finish(context, message, accepted);
            }
            onError: root.finish(context, "System password authentication is unavailable.", false)
        }
    }

    Component.onDestruction: cancel()
}
