// Qt Quick does not automatically scroll arbitrary focused controls into view.
function reveal(item) {
    for (let ancestor = item.parent; ancestor; ancestor = ancestor.parent) {
        if (typeof ancestor.contentY !== "number" || !ancestor.contentItem)
            continue;
        const top = item.mapToItem(ancestor.contentItem, 0, 0).y;
        const height = Math.min(item.height, ancestor.height);
        let target = ancestor.contentY;
        if (top < target) target = top;
        else if (top + height > target + ancestor.height) target = top + height - ancestor.height;
        ancestor.contentY = Math.max(0, Math.min(Math.max(0, ancestor.contentHeight - ancestor.height), target));
    }
}
