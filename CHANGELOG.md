# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Projects mode, the new default for a fresh block: the workspace's projects on a board (one column per project status) or a sortable table (name, status, health, lead, target date, progress, updated), with health badges, lead, target date, progress and team keys.
- Projects / Issues switch in the top bar, with `p` and `i`; the mode is remembered per block.
- Project scopes All projects, My projects (lead or member) and per team; Active (planned, in progress, paused), Backlog and All views; search over name, lead and team keys; lead and health filters.
- Project selection with `j`/`k`/`h`/`l`, arrows and clicks on table rows; `o` opens the project in Linear (linear.app links only), `y` copies its link.
- Live polling of projects: a change check every 30 seconds and a full reload every 5 minutes while Projects mode is on screen.
- Project page: `Enter` on a project the list shows, a click on a project card or activating a table row opens the project full-screen with a **Back** button (`Esc`, `Backspace`), status, health, **Open in Linear** (`o`), copy link (`y`), refresh (`r`) and a tab bar. Its **Overview** tab shows the summary, the project document as sanitized Markdown, the properties (status, health with its last update, priority, lead, members, teams, start and target dates at their Linear precision such as `Q3 2026`, progress, labels) and the milestones in Linear's order with status, progress and target date; two columns on a wide pane, stacked on a narrow one. Back returns to the list with the same mode, scope, view, layout and the project still selected.
- The open project page and its tab are remembered per block; a restored block reopens the page, or shows the list with a notice when the project is gone. A project deleted while its page is open leaves the list. The page reloads on the 30-second poll while the list behind it pauses.
- Project page **Activity** tab, after Overview (`Tab` / `Shift+Tab` or a click): project updates with author, health, time (the exact time on hover), the body as sanitized Markdown, an edited marker and their comments behind the comment count, merged newest first with one-line history events (status, start date, name, icon, description, summary, teams, lead team, milestones added, milestones completed). It loads the first time the tab is shown, offers **Load more** for older items, shows `No activity yet` for a quiet project, reloads on the 30-second poll only while it is on screen, and `r` / Refresh reload the tab on screen. A page saved on its Activity tab reopens on it.

### Fixed

- A background reload left the block marked as refreshing, which stopped the 30-second polling after the first change it picked up (or after any edit) and kept the Refresh button spinning.

## [0.1.0] - 2026-11-10

### Added

- `linear.board` block for Tern, written in pure Luau (host half only; no Node bridge, no background service).
- Board layout with one column per workflow state, and a sortable table layout.
- My issues scope (assigned to you, across teams) and per-team scope; Active, Backlog and All views.
- Search and priority, assignee and label filters.
- Detail drawer with Markdown description, properties, sub-issues, relations and threaded comments.
- Edit title, description, state, priority and assignee; assign to me, mark done, reopen, and move between columns.
- Create issues in a dialog.
- Add and remove blocking and related-issue links by identifier; `Blocked` badge on cards.
- Keyboard-first controls with mouse equivalents.
- Live polling: a change check every 30 seconds, a full reload every 5 minutes, back-off on Linear rate limits.
- In-block setup for a personal API key, with `LINEAR_API_KEY` as an alternative; Sign out for stored keys.
- Remembers layout, view, scope, team and table sort per block.
- Follows the Tern light and dark theme.
- Owner-only key file (`umask 077` on macOS and Linux), `LINEAR_API_URL` restricted to Linear or loopback, and Markdown images and non-http(s) links stripped before display.
- Test suite: unit tests for the pure model and text logic, GraphQL validation against Linear's public schema, a headless end-to-end test against a mock Linear, and a read-only live smoke test.
