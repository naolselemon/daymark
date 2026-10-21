.pragma library

function day(value, today) {
    if (!value) return "No date";
    const date = new Date(value + "T12:00:00");
    if (isNaN(date.getTime())) return value;
    if (today) {
        if (value === today) return "Today";
        const reference = new Date(today + "T12:00:00");
        reference.setDate(reference.getDate() + 1);
        if (value === Qt.formatDate(reference, "yyyy-MM-dd")) return "Tomorrow";
        reference.setDate(reference.getDate() - 2);
        if (value === Qt.formatDate(reference, "yyyy-MM-dd")) return "Yesterday";
    }
    return Qt.formatDate(date, "ddd, d MMM yyyy");
}

function span(start, end) {
    const startFormat = start.slice(0, 4) === end.slice(0, 4) ? "d MMM" : "d MMM yyyy";
    return Qt.formatDate(new Date(start + "T12:00:00"), startFormat)
        + " – " + Qt.formatDate(new Date(end + "T12:00:00"), "d MMM yyyy");
}
