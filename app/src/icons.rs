//! The marks the window draws that OpenCode's icon set has no glyph for. The Windows and Apple
//! logos are the companies' own (Simple Icons), in their own colours; the rest are 24-point
//! line glyphs drawn in the element's colour.

use rune::Icon;

/// The app's own mark (`icons/vmlab.svg`, the launcher's icon).
pub static VMLAB: Icon = Icon::svg("vmlab", include_str!("../icons/vmlab.svg"));

pub static WINDOWS: Icon = Icon {
    name: "windows",
    view: 256.0,
    body: r##"<path fill="#0078D4" d="M0 0h121.33v121.33H0zM134.67 0H256v121.33H134.67zM0 134.67h121.33V256H0zM134.67 134.67H256V256H134.67z"/>"##,
};

pub static APPLE: Icon = Icon::svg(
    "apple",
    r#"<svg viewBox="0 0 256 315"><path fill="currentColor" d="M213.8 167.03c.44 47.58 41.74 63.41 42.2 63.61-.35 1.12-6.6 22.57-21.76 44.72-13.1 19.15-26.7 38.23-48.13 38.63-21.05.39-27.82-12.48-51.89-12.48-24.06 0-31.58 12.09-51.51 12.87-20.68.78-36.43-20.71-49.64-39.79-27-39.03-47.63-110.3-19.93-158.41 13.77-23.89 38.36-39.02 65.06-39.4 20.3-.39 39.47 13.66 51.89 13.66 12.4 0 35.69-16.9 60.18-14.41 10.25.43 39.03 4.14 57.5 31.19-1.49.92-34.33 20.04-33.97 59.81M174.24 50.2c10.98-13.29 18.37-31.79 16.35-50.2-15.83.64-34.97 10.55-46.32 23.83-10.18 11.77-19.09 30.61-16.69 48.67 17.64 1.37 35.67-8.97 46.66-22.3"/></svg>"#,
);

const fn line(name: &'static str, body: &'static str) -> Icon {
    Icon { name, view: 24.0, body }
}

pub static POWER: Icon = line(
    "power",
    r#"<path d="M12 3.5v8M6.6 7a7.5 7.5 0 1 0 10.8 0" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static RESTART: Icon = line(
    "restart",
    r#"<path d="M20 12a8 8 0 1 1-2.34-5.66M20 4.5v4h-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static OPEN: Icon = line(
    "open",
    r#"<path d="M14 5h5v5M19 5l-8 8M18 14v4a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18V7.5A1.5 1.5 0 0 1 5.5 6H10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static PLAY: Icon = line("play", r#"<path d="M7.5 5.5v13l11-6.5z" fill="currentColor"/>"#);
pub static SAVE: Icon = line(
    "save",
    r#"<path d="M5.5 4h10l3 3v11.5a1.5 1.5 0 0 1-1.5 1.5H7a1.5 1.5 0 0 1-1.5-1.5zM8.5 4v4.5h6V4M8.5 20v-5.5h7V20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static STAR: Icon = line(
    "star",
    r#"<path d="m12 4 2.4 5 5.4.6-4 3.7 1.1 5.3L12 16l-4.9 2.6 1.1-5.3-4-3.7 5.4-.6z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static ARROWS: Icon = line(
    "arrows",
    r#"<path d="M4 8.5h13M14 5.5l3 3-3 3M20 15.5H7M10 12.5l-3 3 3 3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static SWITCH: Icon = line(
    "switch",
    r#"<path d="M5 12h12M13 7.5l4.5 4.5-4.5 4.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>"#,
);
pub static INFO: Icon = line(
    "info",
    r#"<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M12 11v5M12 7.8v.2" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>"#,
);
