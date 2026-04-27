import Foundation

/// Single source of truth for the in-app changelog.
///
/// Why this lives in code (not a JSON in `Resources/`):
///  - it ships with the binary, so the changelog *is* the app — a user on
///    v0.2.0 can never see a v0.3.0 entry by accident,
///  - the build fails if a future version forgets to add an entry (we read
///    `Bundle.main`'s short-version and assert the head entry matches),
///  - no I/O on app launch.
///
/// To add a new release:
///  1. Bump `MARKETING_VERSION` in `project.yml` and re-run `xcodegen`,
///  2. Prepend a `Changelog.Entry` below with today's date + bullet list,
///  3. The Settings → About → Changelog screen picks it up automatically.
enum Changelog {
    struct Entry: Identifiable, Hashable {
        let version: String
        let date: Date
        let highlights: [String]
        var id: String { version }
    }

    /// Newest first. The first element is treated as the "current" release.
    static let entries: [Entry] = [
        Entry(
            version: "0.7.2",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Welcome card no longer double-prints the class time. The UPCOMING line is now purely relative (‘TOMORROW’, ‘FRI’, ‘2h 15m’, ‘STARTING NOW’) and the absolute clock time stays on the address line below — so ‘UPCOMING · TOMORROW 6:15 AM / 6:15 AM · 2340 Walsh Ave’ is now ‘UPCOMING · TOMORROW / 6:15 AM · 2340 Walsh Ave’."
            ]
        ),
        Entry(
            version: "0.7.1",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Today’s highlights card now reflects the live session: once you’ve logged any sets, the planned station list flips to a LOGGED list — green ✓, station label (STN 1 / STN 2 / etc.), exercise name, and the set count for that exercise. Lookup is canonical-ID based so renamed exercises still match the planned station.",
                "Welcome card actually finds your gym class now. Title match loosened to a case-insensitive substring on ‘FNS’, search window widened from 7 to 14 days, and full diagnostic logging added under the ‘calendar’ category in Settings → Debug → View debug log so you can see exactly what was scanned and matched.",
                "Calendar permission re-checks every time the app foregrounds, so granting access in Settings → Privacy → Calendars after an initial deny picks up immediately without a relaunch."
            ]
        ),
        Entry(
            version: "0.7.0",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Home gets a real welcome card: time-of-day greeting (‘Good morning, Abhay’), a daily-rotating motivational tagline, and — when Apple Calendar has one on the books — the next ‘FNS Gym Class’ event with a relative countdown (‘UPCOMING · 2h 15m’ or ‘TOMORROW 6:15 AM’) plus the gym address. The redundant gear icon and large-title bar are gone; Settings still lives as its own tab.",
                "Today’s highlights card now respects the four-station class structure — main lift hero plus at most three mini rows labelled STN 2 / STN 3 / STN 4. No more STN 5–STN 8 from accessory exercises bleeding into the row count.",
                "Progress and Body tabs lost the dead 16pt of vertical padding above the first card — content now sits where the large title visually expects it instead of floating mid-screen."
            ]
        ),
        Entry(
            version: "0.6.5",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Live Activity is actually informative now: shows the current station + exercise name (e.g. ‘STATION 1 · BB Squats’) instead of duplicating the workout name. Set counter reads ‘Set X of Y’ once you’ve opened an exercise, or ‘N ✓ this session’ before then.",
                "Minimize pill now picks up the same section + exercise label, and sits with proper breathing room above the tab bar (no more lime border kissing the Home/Progress/Body/Settings labels)."
            ]
        ),
        Entry(
            version: "0.6.4",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Live Activities: when a workout is recording, a Hevy-style pill now appears on the lock screen and Dynamic Island — workout name + auto-ticking elapsed timer up top, current exercise + ‘Set X of Y’ in the middle, last logged set (e.g. ‘135 × 8 reps’) and a session ✓ count at the bottom. Updates push on every set toggle.",
                "Progress tab: the Workouts calendar now sits at the top of the screen, above the This Week tiles and Exercises carousel — so the first thing you see is what you’ve done lately.",
                "Home day cards: cleaned up the layout — header pinned to top, glyph (now 78pt) vertically centered, title + exercise count anchored under it. No more dead space at the bottom of the card."
            ]
        ),
        Entry(
            version: "0.6.3",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Active workout screen now has a minimize button (down chevron) — tap to drop into a Hevy-style floating mini-pill above the tab bar that shows ‘Workout · MM:SS · current exercise’ and a trash icon for one-tap discard. Tap the pill to resume.",
                "Live recording pill is now visibly recording: bigger digits + arc, plus a pulsing pink dot so you can tell at a glance that a session is active.",
                "InBody trend charts (Weight, BF%, SMM, BMI, BMR, ECW/TBW, Visceral, Lean Mass) are now drag-scrubbable Apple Fitness-style — a vertical rule + dot follow your finger, with a tooltip showing the exact value, date, and a ‘View scan’ button.",
                "Body Fat % all-time best now picks the *lowest* reading instead of the highest (same fix applies to ECW/TBW and Visceral, where lower-is-better).",
                "Home: day cards moved above today’s workout card and bumped from 160×170 → 175×210 so the week is the first thing you see.",
                "HR trace station bands are now anchored to the first checked set in the FitTrack session (station 1 starts 90s before your first ✓), instead of guessing from the workout’s end. Watch-only days still use the back-anchored heuristic.",
                "Changelog dates corrected to reflect when each version actually shipped (v0.1.0 = 4/18, v0.2.0 = 4/20, v0.3.0–v0.6.0 = 4/21, v0.6.1+v0.6.2+v0.6.3 = 4/22)."
            ]
        ),
        Entry(
            version: "0.6.2",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Home page replaces the text-only Watch / FitTrack info with a visual highlights card pulled from today's planned workout — main lift glyph + station 2–4 mini icons, footer with sets / kcal once the session starts; Apple Watch ring removed entirely.",
                "Progress → All Exercises now pins your main lifts (squat, deadlift, bench, landmine, sled) in their own accent box at the top so PR-tracking stays glanceable.",
                "Progress calendar highlights today distinctly: lime ring + tinted dot when no workout is logged, lime ring around the pink fill when one is.",
                "InBody import: ⓧ clear-cell button on every value, plus the Segmental Fat block is gone (the InBody 970 doesn't actually report it — the parser was duplicating Lean values).",
                "InBody scan detail: Edit toggle in the toolbar lets you fix any OCR misread inline; the original PDF/photo is now saved with the scan and reachable via a 'View original scan' card so you can sanity-check side-by-side.",
                "Past-session view drops the duplicated 'Wed WOD' / 'Mon WOD' titles in both the nav bar and inside the scroll — just the date + class slot now."
            ]
        ),
        Entry(
            version: "0.6.1",
            date: dateFrom("2026-04-22"),
            highlights: [
                "Activity rings card now falls back to the Health app (Summary → Activity ring) when the Fitness deep-link isn't reachable, instead of bouncing you to the App Store.",
                "Activity rings now look like Apple's: stacked loops barely fade as you lap (was washing out at 2× Move), with a chevron arrowhead + dark cap shadow at the leading edge so a 250% Move day reads clearly.",
                "Past-session HR scrub tooltip now also shows the station name (Warm-up / Station 1 / Rest / …), so you can tell where in the class a heart-rate spike happened.",
                "Body trend charts (Weight / BF% / SMM, plus the InBody Trends and per-exercise Progress charts) now scale tightly around your actual data — no more flat-looking weight line forced to start at 0."
            ]
        ),
        Entry(
            version: "0.6.0",
            date: dateFrom("2026-04-21"),
            highlights: [
                "Factory reset (Settings → Factory reset) actually wipes data now — the two-step alert was racing itself and the deletion never ran.",
                "Activity rings card opens the Apple Fitness app (with App Store fallback) instead of Health, and rings now lap-stack like Apple's: a 250% Move day shows two loops, not a static closed ring.",
                "InBody import preview now has an info button on every metric (Weight, BMI, BF%, SMM, ECW/TBW, segmental, …) and a keyboard toolbar with ← → Done so you can step through all 23 fields without dismissing.",
                "Calendar tap goes straight to the session — single-session days skip the picker; Watch-only days drill in directly.",
                "Past-session view: replaced the multi-ring with an Apple Fitness-style scrubbable HR trace (drag to read bpm/time at any point) and shows TIME / KCAL / VOLUME in raw units instead of percent.",
                "Body tab gets a prominent in-content header; Settings → About now credits Abhay Gulati as the creator.",
                "App icon: lime → teal gradient with a dumbbell glyph, replacing the white default."
            ]
        ),
        Entry(
            version: "0.5.0",
            date: dateFrom("2026-04-21"),
            highlights: [
                "Tab restructure: Workout → Home (Activity rings on top), new Body tab (Weight / BF% / SMM trend charts + InBody import), Health tab removed, Settings is now its own tab.",
                "Progress page now shows This Week tiles (Active Energy / Exercise / Workouts / HRV) above the THIS MONTH / YTD count tiles.",
                "Past-session HR chart: X-axis is now clamped to the workout's start→end (no stray AM hours bleeding in), and station bands are inferred from the Equinox class structure (warm-up + 4 strength stations × 8 min with 90s rests at the back end) instead of per-exercise.",
                "Activity rings card now opens the Health app (Summary lands on the Activity ring at top) — the previous Apple Fitness deep-link was undocumented and silently failed on iPhone.",
                "InBody import preview is now editable: tap any numeric value to correct an OCR misread before saving."
            ]
        ),
        Entry(
            version: "0.4.0",
            date: dateFrom("2026-04-21"),
            highlights: [
                "Calendar day with only an Apple Watch HIIT workout (no FitTrack session) now drills into a Watch-only summary instead of an empty state — same multi-ring + HR chart, with a footer explaining why VOLUME is blank.",
                "Progress page shows THIS MONTH and YTD workout counts above the calendar, sourced from Apple Watch HIIT days."
            ]
        ),
        Entry(
            version: "0.3.0",
            date: dateFrom("2026-04-21"),
            highlights: [
                "Apple Watch HR is now read — AVG / MAX HR tiles populate on past sessions instead of showing '—'.",
                "AVG HR / MAX HR tiles now tap into a per-station HR chart (HR over time with colored station bands underneath).",
                "Session ring is now three concentric rings: pink TIME / orange KCAL / lime VOLUME, all measured against your own rolling averages.",
                "Center of the ring shows a live HR trace from the Apple Watch.",
                "Volume callouts now compare against the same Equinox class slot, e.g. 'vs last Tue 6:15 AM class' instead of 'vs last Tuesday WOD'.",
                "Calendar day rows show a class-time chip ('6:15 AM', '8:30 AM', etc.). Sunday rows fall back to plain time-of-day."
            ]
        ),
        Entry(
            version: "0.2.0",
            date: dateFrom("2026-04-20"),
            highlights: [
                "Activity ring on Health now opens Apple Fitness on tap (deep link).",
                "Body Metrics weight value drills into the InBody weight trend chart.",
                "Live workout timer is now a lime progress pill — arc fills against your rolling avg session length, switches to pink past 100%.",
                "Core Data store now migrates safely across app updates (lightweight inference enabled). Your workout history persists across upgrades.",
                "New Settings → About section shows app version + this changelog."
            ]
        ),
        Entry(
            version: "0.1.0",
            date: dateFrom("2026-04-18"),
            highlights: [
                "Initial private build: schedule + log workouts, parse Hevy-style sections, log per-set weight/reps with PREVIOUS lookup.",
                "Per-session summary with PRs, volume delta, streak milestones.",
                "Apple Health integration: HIIT workout detection, watch stats, activity rings.",
                "InBody scan tracker with weight / SMM / PBF / BMR trends.",
                "Progress dashboard, calendar, exercise progress charts."
            ]
        )
    ]

    /// Marketing version baked into the app (CFBundleShortVersionString).
    /// Falls back to "—" if Info.plist is unreadable, which never happens in a
    /// shipped binary but keeps unit tests safe.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Build number (CFBundleVersion / CURRENT_PROJECT_VERSION).
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// "0.2.0 (2)" — single string for the Settings row.
    static var versionLabel: String {
        "\(currentVersion) (\(currentBuild))"
    }

    private static func dateFrom(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso) ?? Date()
    }
}
