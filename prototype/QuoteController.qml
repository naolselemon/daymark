import QtQuick
import "Quotes.js" as Quotes

// This controller knows only public quotes. It never receives a store or record.
Item {
    id: root
    objectName: "quoteController"
    visible: false

    property bool active: false
    property bool onlineEnabled: true
    property string quote: Quotes.reflections[0]
    property string author: "Daymark"
    property string source: "local"
    property bool busy: false
    // Internal native-test seam, deliberately not exposed as a user setting.
    property string endpoint: "https://zenquotes.io/api/quotes"
    readonly property int cacheLifetime: 60 * 60 * 1000
    readonly property int attemptCooldown: 60 * 1000
    readonly property int maximumResponseBytes: 128 * 1024
    property var cachedQuotes: []
    property real cacheCreatedAt: 0
    property string cacheEndpoint: ""
    property real lastAttemptAt: -1
    property int lastLocalIndex: -1
    property string lastProviderQuote: ""
    property var request: null
    property real generation: 0
    property bool initialized: false
    property bool disposed: false

    function chooseIndex(length, previous) {
        if (length <= 1) return 0;
        if (previous < 0) return Math.floor(Math.random() * length);
        const index = Math.floor(Math.random() * (length - 1));
        return index >= previous ? index + 1 : index;
    }

    function showLocal() {
        lastLocalIndex = chooseIndex(Quotes.reflections.length, lastLocalIndex);
        quote = Quotes.reflections[lastLocalIndex];
        author = "Daymark";
        source = "local";
    }

    function showProvider(pool) {
        let previous = -1;
        for (let i = 0; i < pool.length; ++i) {
            if (pool[i].quote === lastProviderQuote) {
                previous = i;
                break;
            }
        }
        const chosen = pool[chooseIndex(pool.length, previous)];
        lastProviderQuote = chosen.quote;
        quote = chosen.quote;
        author = chosen.author;
        source = "zenquotes";
    }

    // responseText may be exposed during LOADING or only at DONE in native XHR.
    // Count UTF-8 bytes, not just UTF-16 code units, as soon as text is available.
    function responseTooLarge(text) {
        if (text.length > maximumResponseBytes) return true;
        let bytes = 0;
        for (let i = 0; i < text.length; ++i) {
            const code = text.charCodeAt(i);
            if (code <= 0x7f) bytes += 1;
            else if (code <= 0x7ff) bytes += 2;
            else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length
                    && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
                bytes += 4;
                ++i;
            } else bytes += 3;
            if (bytes > maximumResponseBytes) return true;
        }
        return false;
    }

    function validQuotes(value) {
        if (!Array.isArray(value)) return [];
        const result = [];
        const seen = Object.create(null);
        for (let i = 0; i < value.length; ++i) {
            const record = value[i];
            if (!record || typeof record.q !== "string" || typeof record.a !== "string"
                    || record.q.length > 1000 || record.a.length > 120) continue;
            const text = record.q.trim();
            const writer = record.a.trim();
            if (!text || !writer || seen[text]) continue;
            seen[text] = true;
            // Only plain q/a strings survive validation; provider HTML is unused.
            result.push({quote: text, author: writer});
        }
        return result;
    }

    function releaseRequest(abort) {
        // Invalidate before abort: native XHR may notify synchronously on abort.
        ++generation;
        requestTimeout.stop();
        const pending = request;
        request = null;
        busy = false;
        if (pending) {
            pending.onreadystatechange = null;
            if (abort) {
                try { pending.abort(); } catch (error) { /* Already closed. */ }
            }
        }
    }

    function activate() {
        releaseRequest(true);
        showLocal();
        if (!active || disposed || !onlineEnabled) return;

        const now = Date.now();
        const cacheAge = now - cacheCreatedAt;
        if (cacheEndpoint === endpoint && cachedQuotes.length > 0
                && cacheAge >= 0 && cacheAge < cacheLifetime) {
            showProvider(cachedQuotes);
            return;
        }
        if (lastAttemptAt >= 0 && now - lastAttemptAt < attemptCooldown) return;

        lastAttemptAt = now;
        const token = generation;
        const requestedEndpoint = endpoint;
        let xhr;
        try {
            xhr = new XMLHttpRequest();
            request = xhr;
            busy = true;
            xhr.onreadystatechange = function() {
                if (!root.active || !root.onlineEnabled || root.disposed || root.generation !== token || root.request !== xhr) return;
                if (xhr.readyState < XMLHttpRequest.LOADING) return;
                try {
                    const body = xhr.responseText;
                    if (root.responseTooLarge(body)) {
                        root.releaseRequest(true);
                        return;
                    }
                    if (xhr.readyState !== XMLHttpRequest.DONE) return;
                    if (xhr.status < 200 || xhr.status >= 300) {
                        root.releaseRequest(false);
                        return;
                    }
                    const pool = root.validQuotes(JSON.parse(body));
                    root.releaseRequest(false);
                    if (!root.active || !root.onlineEnabled || root.disposed || pool.length === 0) return;
                    root.cachedQuotes = pool;
                    root.cacheCreatedAt = Date.now();
                    root.cacheEndpoint = requestedEndpoint;
                    root.showProvider(pool);
                } catch (error) {
                    root.releaseRequest(true);
                }
            };
            xhr.open("GET", requestedEndpoint, true);
            requestTimeout.requestGeneration = token;
            requestTimeout.start();
            xhr.send();
        } catch (error) {
            releaseRequest(true);
        }
    }

    onActiveChanged: {
        if (!initialized) return;
        if (active) activate();
        else releaseRequest(true);
    }
    onOnlineEnabledChanged: {
        if (!initialized) return;
        releaseRequest(true);
        cachedQuotes = [];
        cacheCreatedAt = 0;
        cacheEndpoint = "";
        if (!onlineEnabled) showLocal();
        else if (active) activate();
    }
    onEndpointChanged: {
        if (initialized) releaseRequest(true);
    }
    Component.onCompleted: {
        initialized = true;
        if (active) activate();
    }
    Component.onDestruction: {
        disposed = true;
        releaseRequest(true);
    }

    Timer {
        id: requestTimeout
        objectName: "quoteRequestTimeout"
        property real requestGeneration: -1
        interval: 8000
        repeat: false
        onTriggered: {
            if (requestGeneration === root.generation) root.releaseRequest(true);
        }
    }
}
