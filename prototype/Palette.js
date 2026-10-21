.pragma library

function luminance(color) {
    function linear(value) { return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4); }
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
}

function ink(accent, background, foreground) {
    const value = luminance(accent);
    function contrast(color) {
        const other = luminance(color);
        return (Math.max(value, other) + 0.05) / (Math.min(value, other) + 0.05);
    }
    return contrast(background) >= contrast(foreground) ? background : foreground;
}
