import QtQuick

QtObject {
    id: root
    required property var transport
    property var records: ({revision: -1, today: "", activities: [], sessions: [], dayNotes: {}, events: [], categories: [], projects: [], trash: [], daySummaries: {}, insights: null})
    readonly property string today: records.today || Qt.formatDate(new Date(), "yyyy-MM-dd")
    property string date: today
    readonly property var activities: records.activities
    readonly property var sessions: records.sessions
    readonly property var events: records.events
    readonly property var trash: records.trash
    readonly property var insights: records.insights
    readonly property var activitiesById: {
        const result = Object.create(null);
        activities.forEach(a => { result[a.id] = a; });
        return result;
    }
    readonly property var sessionsByActivity: {
        const result = Object.create(null);
        sessions.forEach(s => {
            if (!result[s.activityId]) result[s.activityId] = [];
            result[s.activityId].push(s);
        });
        return result;
    }
    readonly property var dayNotes: {
        const result = {};
        Object.keys(records.dayNotes).forEach(day => { result[day] = records.dayNotes[day].body; });
        return result;
    }
    property bool loaded: false
    readonly property bool busy: pending !== null || queue.length > 0
    property string lastError: ""
    property var noteDrafts: ({})
    property var noteStatus: ({})
    property var noteErrors: ({})
    property var dirtyNotes: ({})
    property var noteState: ({})
    readonly property bool hasUnsavedNotes: Object.keys(dirtyNotes).length > 0
    property var historyEntries: []
    property var historyNotes: []
    property var historyCompletions: []
    property bool historyLoading: false
    property string historyError: ""
    property var historyFilters: ({query: "", kind: "activities"})
    property int historyGeneration: 0
    property int historyOffset: 0
    property int historyTotal: 0
    property bool historyHasMore: false
    property var restoreRetry: null
    property int requestCounter: 0
    property var queue: []
    property var pending: null
    readonly property var legacySessions: sessions.filter(s => s.source === "timer" && s.status !== "stopped")
    property bool legacyBusy: false
    property string legacyError: ""
    property var legacyRetry: null
    property bool externalReloadNeeded: false

    function newRequestId() {
        return "ui-" + Date.now().toString(36) + "-" + (++requestCounter).toString(36)
            + "-" + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
    }
    function changed(map, key, value) {
        const next = Object.assign({}, map);
        if (value === undefined) delete next[key];
        else next[key] = value;
        return next;
    }
    function validDate(value, allowEmpty) {
        if (value === "" && allowEmpty) return true;
        if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
        const year = Number(value.slice(0, 4)), month = Number(value.slice(5, 7)), day = Number(value.slice(8, 10));
        const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
        const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        return year > 0 && month > 0 && month <= 12 && day > 0 && day <= days[month - 1];
    }
    function activity(id) { return activitiesById[id] || null; }
    function sessionsFor(id) { return sessionsByActivity[id] || []; }
    function planned(day) { return activities.filter(a => a.status === "open" && a.plannedFor === day); }
    function overdue(day) { return activities.filter(a => a.status === "open" && a.plannedFor && a.plannedFor < day); }
    function timeline(day) {
        return sessions.filter(s => s.days ? s.days.some(d => d.date === day) : s.date === day)
            .map(s => s.days
                ? Object.assign({}, s, {date: day, minutes: s.days.find(d => d.date === day).seconds / 60, slice: true})
                : s);
    }
    function completionOnly(day) {
        return activities.filter(a => a.status === "done" && a.completedDate === day && !sessionsByActivity[a.id]);
    }
    function request(op, args, callback, requestId) {
        const id = requestId || newRequestId();
        queue = queue.concat([{envelope: {protocol: 1, requestId: id, op: op, args: args}, callback: callback}]);
        Qt.callLater(pump);
        return id;
    }
    function pump() {
        if (pending || queue.length === 0) return;
        pending = queue[0];
        queue = queue.slice(1);
        try {
            if (!transport.send(JSON.stringify(pending.envelope)))
                acceptReply("", "The process transport could not accept this request. Retry your retained draft.");
        } catch (_) {
            acceptReply("", "The process transport is unavailable. Retry your retained draft.");
        }
    }
    function validSnapshot(snapshot) {
        return snapshot && typeof snapshot.revision === "number" && validDate(snapshot.today, false)
            && Array.isArray(snapshot.activities) && Array.isArray(snapshot.sessions)
            && snapshot.dayNotes && Array.isArray(snapshot.events)
            && Array.isArray(snapshot.categories) && Array.isArray(snapshot.projects)
            && Array.isArray(snapshot.trash) && snapshot.daySummaries
            && snapshot.insights && Array.isArray(snapshot.insights.days) && snapshot.insights.byActivity;
    }
    function acceptReply(text, transportError) {
        if (!pending) return;
        const job = pending;
        let response;
        if (transportError) {
            response = {ok: false, error: {code: "transport", message: transportError}};
        } else {
            try {
                response = JSON.parse(text);
                if (response.protocol !== 1 || response.requestId !== job.envelope.requestId || typeof response.ok !== "boolean")
                    throw new Error("Invalid envelope");
                if (response.ok && !validSnapshot(response.snapshot))
                    throw new Error("Invalid snapshot");
                if (response.ok && job.envelope.op === "history" && (!response.result || !Array.isArray(response.result.sessions)
                        || !Array.isArray(response.result.notes) || !Array.isArray(response.result.completions)))
                    throw new Error("Invalid history");
                if (!response.ok && (!response.error || typeof response.error.message !== "string"))
                    throw new Error("Invalid error");
            } catch (_) {
                response = {ok: false, error: {code: "protocol", message: "The helper returned an invalid response. Your draft is retained; retry safely."}};
            }
        }
        if (response.ok) {
            if (response.snapshot && response.snapshot.revision >= records.revision) {
                const changedRecords = !loaded || response.snapshot.revision !== records.revision || response.snapshot.today !== records.today;
                records = response.snapshot;
                loaded = true;
                if (changedRecords && job.envelope.op !== "history") refreshHistory();
            }
            lastError = "";
        } else lastError = response.error.message;
        // Keep busy true through acknowledgements: close guards must not see an
        // idle store before forms/drafts have processed the committed response.
        if (job.callback) job.callback(response.ok, response.result || {}, response.error || {});
        pending = null;
        Qt.callLater(pump);
        if (externalReloadNeeded) externalReload.restart();
        if (!legacyBusy && loaded) {
            if (legacySessions.length === 0) {
                legacyError = "";
                legacyRetry = null;
            } else if (!legacyError) settleLegacyTimers();
        }
    }
    function reload() { request("snapshot", {}, null); }
    function createActivity(fields, callback, requestId) { return request("create_activity", fields, callback, requestId); }
    function addSession(id, fields, callback, requestId) {
        return request("add_session", Object.assign({}, fields, {activityId: id}), callback, requestId);
    }
    function updateActivity(id, fields, callback, requestId) {
        return request("update_activity", Object.assign({}, fields, {activityId: id}), callback, requestId);
    }
    function setDone(id, done, callback, requestId) { return request("set_done", {activityId: id, done: done}, callback, requestId); }
    function updateSession(id, fields, callback, requestId) {
        return request("update_session", Object.assign({}, fields, {sessionId: id}), callback, requestId);
    }
    function deleteRecord(kind, id, expectedRevision, callback, requestId) {
        return request("delete_record", {kind: kind, id: id, expectedRevision: expectedRevision}, callback, requestId);
    }
    function undoDelete(trashId, callback, requestId) {
        return request("undo_delete", {trashId: trashId}, callback, requestId);
    }
    function purgeDeleted(trashId, callback, requestId) {
        return request("purge_deleted", {trashId: trashId, confirmed: true}, callback, requestId);
    }
    function exportRecords(format, path, callback, requestId) {
        return request("export_records", {format: format, path: path}, callback, requestId);
    }
    function restoreRecords(path, callback, requestId) {
        if (hasUnsavedNotes) {
            callback(false, {}, {code: "unsaved", message: "Save or explicitly discard daily-note drafts before restoring."});
            return "";
        }
        const id = requestId || newRequestId();
        const args = restoreRetry && restoreRetry.id === id && restoreRetry.args.path === path
            ? restoreRetry.args : {path: path, expectedRevision: records.revision};
        restoreRetry = {id: id, args: args};
        return request("restore_records", args, (ok, result, error) => {
            if (ok && restoreRetry && restoreRetry.id === id) restoreRetry = null;
            callback(ok, result, error);
        }, id);
    }

    function settleLegacyTimers(callback) {
        if (legacyBusy) return "";
        if (!loaded) {
            reload();
            return "";
        }
        if (!legacySessions.length) {
            legacyError = "";
            legacyRetry = null;
            if (callback) callback(true, {retiredSessions: 0}, {});
            return "";
        }
        const signature = legacySessions.map(s => s.id + ":" + s.intervalId + ":" + s.checkpointAt + ":" + s.status).sort().join("|");
        const requestId = legacyRetry && legacyRetry.signature === signature ? legacyRetry.requestId : newRequestId();
        legacyRetry = {signature: signature, requestId: requestId};
        legacyBusy = true;
        return request("settle_legacy_timers", {}, (ok, result, error) => {
            legacyBusy = false;
            if (ok) {
                legacyError = "";
                legacyRetry = null;
            } else {
                legacyError = "Older timed entries could not be closed at their last saved checkpoint. No extra time is counted. " + error.message;
            }
            if (callback) callback(ok, result, error);
        }, requestId);
    }
    function noticeExternalChange() {
        externalReloadNeeded = true;
        externalReload.restart();
    }

    function noteFor(day) { return noteDrafts[day] !== undefined ? noteDrafts[day] : (dayNotes[day] || ""); }
    function discardNote(day) {
        if (!noteErrors[day] || (noteState[day] && noteState[day].inFlight)) return;
        noteDrafts = changed(noteDrafts, day, undefined);
        dirtyNotes = changed(dirtyNotes, day, undefined);
        noteErrors = changed(noteErrors, day, undefined);
        noteState = changed(noteState, day, undefined);
        noteStatus = changed(noteStatus, day, "Draft discarded");
    }
    function editNote(day, body) {
        if (!loaded || !validDate(day, false) || body === noteFor(day)) return;
        const meta = Object.assign({}, noteState[day] || {generation: 0, baseRevision: records.dayNotes[day] ? records.dayNotes[day].revision : 0});
        if (!dirtyNotes[day] && !meta.inFlight)
            meta.baseRevision = records.dayNotes[day] ? records.dayNotes[day].revision : 0;
        meta.generation += 1;
        noteState = changed(noteState, day, meta);
        noteDrafts = changed(noteDrafts, day, body);
        dirtyNotes = changed(dirtyNotes, day, true);
        noteStatus = changed(noteStatus, day, noteErrors[day] ? "Not saved · draft retained" : meta.inFlight ? "Saving · newer edits pending" : "Unsaved changes");
        noteTimer.restart();
    }
    function flushNotes() {
        noteTimer.stop();
        if (!loaded) return;
        Object.keys(dirtyNotes).forEach(day => {
            const meta = Object.assign({}, noteState[day]);
            if (meta.inFlight || noteErrors[day]) return;
            const args = {date: day, body: noteDrafts[day], expectedRevision: meta.baseRevision};
            const payload = JSON.stringify(args);
            const requestId = meta.retryPayload === payload ? meta.retryId : newRequestId();
            const generation = meta.generation;
            meta.inFlight = true;
            meta.retryPayload = payload;
            meta.retryId = requestId;
            noteState = changed(noteState, day, meta);
            noteStatus = changed(noteStatus, day, "Saving…");
            request("save_note", args, (ok, result, error) => {
                const latest = Object.assign({}, noteState[day]);
                latest.inFlight = false;
                if (ok) {
                    latest.baseRevision = result.revision;
                    latest.retryPayload = "";
                    latest.retryId = "";
                    const committed = records.dayNotes[day];
                    if (committed && committed.revision > result.revision) {
                        noteErrors = changed(noteErrors, day, {code: "conflict", message: "A newer saved version exists. Your draft is retained.", currentNote: Object.assign({date: day}, committed)});
                        noteStatus = changed(noteStatus, day, "Conflict · choose which version to keep");
                    } else if (latest.generation === generation) {
                        noteDrafts = changed(noteDrafts, day, undefined);
                        dirtyNotes = changed(dirtyNotes, day, undefined);
                        noteErrors = changed(noteErrors, day, undefined);
                        noteStatus = changed(noteStatus, day, "Saved");
                    } else {
                        noteStatus = changed(noteStatus, day, "Unsaved newer edits");
                        noteTimer.restart();
                    }
                } else {
                    noteErrors = changed(noteErrors, day, error);
                    noteStatus = changed(noteStatus, day, error.code === "conflict" ? "Conflict · draft retained" : "Save failed · draft retained");
                }
                noteState = changed(noteState, day, latest);
            }, requestId);
        });
    }
    function retryNote(day, overwrite) {
        const error = noteErrors[day];
        if (error && error.code === "conflict") {
            if (!overwrite || !error.currentNote) return;
            const meta = Object.assign({}, noteState[day], {baseRevision: error.currentNote.revision, retryId: "", retryPayload: ""});
            noteState = changed(noteState, day, meta);
        }
        noteErrors = changed(noteErrors, day, undefined);
        flushNotes();
    }
    function useSavedNote(day) {
        const error = noteErrors[day];
        if (!error || error.code !== "conflict" || !error.currentNote || (noteState[day] && noteState[day].inFlight)) return;
        records = Object.assign({}, records, {dayNotes: changed(records.dayNotes, day, error.currentNote)});
        noteDrafts = changed(noteDrafts, day, undefined);
        dirtyNotes = changed(dirtyNotes, day, undefined);
        noteErrors = changed(noteErrors, day, undefined);
        noteState = changed(noteState, day, {generation: 0, baseRevision: error.currentNote.revision});
        noteStatus = changed(noteStatus, day, "Using saved version");
        reload();
    }
    function setHistoryFilters(query, kind) {
        const filters = {query: query, kind: kind === undefined ? "activities" : kind};
        if (JSON.stringify(filters) === JSON.stringify(historyFilters)) return;
        historyFilters = filters;
        historyOffset = 0;
        historyEntries = [];
        historyNotes = [];
        historyCompletions = [];
        historyTotal = 0;
        historyHasMore = false;
        refreshHistory();
    }
    function refreshHistory() {
        historyGeneration += 1;
        historyLoading = true;
        historyError = "";
        historyTimer.restart();
    }
    function loadMoreHistory() {
        if (historyLoading || !historyHasMore) return;
        historyOffset += 100;
        refreshHistory();
    }
    function loadPreviousHistory() {
        if (historyLoading || historyOffset === 0) return;
        historyOffset = Math.max(0, historyOffset - 100);
        refreshHistory();
    }
    function loadHistory() {
        const generation = historyGeneration;
        request("history", Object.assign({}, historyFilters, {offset: historyOffset, limit: 100}), (ok, result, error) => {
            if (generation !== historyGeneration) return;
            historyLoading = false;
            historyError = ok ? "" : error.message;
            if (!ok) return;
            historyTotal = result.total;
            if (historyOffset > 0 && historyOffset >= result.total) {
                historyOffset = Math.max(0, Math.floor((result.total - 1) / 100) * 100);
                refreshHistory();
                return;
            }
            historyEntries = result.sessions;
            historyNotes = result.notes;
            historyCompletions = result.completions;
            historyHasMore = result.hasMore;
        });
    }
    property Timer noteTimer: Timer { interval: 350; onTriggered: root.flushNotes() }
    property Timer historyTimer: Timer { interval: 120; onTriggered: root.loadHistory() }
    property Timer externalReload: Timer {
        interval: 120
        onTriggered: {
            if (root.busy) return;
            root.externalReloadNeeded = false;
            root.reload();
        }
    }
    property Connections transportSignals: Connections {
        target: root.transport
        function onFinished(response, transportError) { root.acceptReply(response, transportError); }
        function onDataChanged() { root.noticeExternalChange(); }
    }
    Component.onCompleted: Qt.callLater(reload)
}
