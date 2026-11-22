// End-to-end test: headless Tern + the plugin against test/mock-linear.mjs, driven through the real UI.
//   bun test/e2e.mjs
// Screenshots go to e2e-artifacts/shots/, the report to e2e-artifacts/report.json.
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { BLOCK_SELECTOR, createRunner, repoRoot, startTern, waitFor } from "./harness.mjs";
import { startMock } from "./mock-linear.mjs";

const artifacts = join(repoRoot, "e2e-artifacts");
const ternOut = join(artifacts, "tern-out");
const COMMENT = "Ship it 🚀 — привет";
const NEW_TITLE = "E2E created issue";
const BAD_KEY = "nope";

rmSync(artifacts, { recursive: true, force: true });
mkdirSync(artifacts, { recursive: true });

const mock = await startMock();
// No LINEAR_API_KEY: the run starts at the setup screen.
let t = await startTern({ env: { LINEAR_API_URL: mock.url }, out: ternOut, size: "1440 900" });
const runner = createRunner(t, { dir: artifacts, title: "tern-linear e2e" });

const role = (name) => `[data-role='linear.${name}']`;
const exists = async (selector) => ((await t.tree(selector)).nodes ?? []).length > 0;
const nodesOf = async (selector) => (await t.tree(selector)).nodes ?? [];

// `plugins expect` only sees the first ~200 characters of the surface and nothing inside overlays, so every
// text assertion polls the element tree instead.
const see = (text) => t.waitFor(BLOCK_SELECTOR, text);
const gone = (text) => t.gone(BLOCK_SELECTOR, text);
const present = (selector) =>
	waitFor(async () => (await t.wait(150), exists(selector)), { what: `${selector} to appear`, interval: 0 });
const absent = (selector) =>
	waitFor(async () => (await t.wait(150), !(await exists(selector))), { what: `${selector} to disappear`, interval: 0 });

const opsSince = (mark, name) => mock.log.slice(mark).filter((entry) => entry.operationName === name);
const mark = () => mock.log.length;
const issueNamed = (identifier) => mock.state().issues.find((issue) => issue.identifier === identifier);
const issueById = (id) => mock.state().issues.find((issue) => issue.id === id);
const teamState = (teamKey, name) =>
	mock.state()
		.teams.find((team) => team.key === teamKey)
		.states.find((state) => state.name === name);

/** Resolves once no new request has reached the mock for `quietMs`. */
async function settle(quietMs = 800) {
	let seen = -1;
	let since = Date.now();
	await waitFor(
		() => {
			if (mock.log.length !== seen) {
				seen = mock.log.length;
				since = Date.now();
			}
			return Date.now() - since >= quietMs;
		},
		{ what: "network to settle", timeout: 20_000, interval: 100 },
	);
}

/**
 * Advances app time until the poll tick reloads the open project page's detail, then lets the network settle. The
 * next tick is then about 30 s of app time away, so the checks that follow can count requests without seeing one.
 */
async function afterPageTick() {
	const before = mark();
	for (let advanced = 0; opsSince(before, "Project").length === 0; advanced += 1000) {
		if (advanced > 31_000) throw new Error("no poll tick reloaded the project page");
		await t.wait(1000);
	}
	await settle();
}

const backspaces = async (count) => {
	for (let i = 0; i < count; i += 1) await t.key("Backspace");
};

async function closeDrawer() {
	for (let attempt = 0; attempt < 4 && (await exists(role("drawer"))); attempt += 1) await t.key("Escape");
	await absent(role("drawer"));
}

/** Focuses the search field, types `query`, and leaves the field (the text stays). */
async function search(query) {
	await t.key("/");
	await t.type(query);
	await t.key("Escape");
}

const SELECT_MENU = ".sf-select-menu";

/** Opens a select of the filter row (by role) and picks the option labelled `label`. */
async function pick(selectRole, label) {
	await t.click(role(selectRole));
	await present(SELECT_MENU);
	const options = (await nodesOf(`${SELECT_MENU} .sf-select-opt`)).map((node) => node.text);
	const index = options.indexOf(label);
	if (index < 0) throw new Error(`${selectRole} has no option ${label}: ${options.join(", ")}`);
	await t.click(`${SELECT_MENU} .sf-select-opt:nth-child(${index + 1})`);
	await absent(SELECT_MENU);
}

async function clearSearch(length) {
	await t.key("/");
	await backspaces(length);
	await t.key("Escape");
}

const assertEqual = (actual, expected, what) => {
	if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
};

// Projects mode. Board order: status column (type rank, then position), then priority inside a column.
const ACTIVE_PROJECTS = "Search revamp,Onboarding redesign,Sync engine v2,Desktop app,Public API";
const MY_PROJECTS = "Search revamp,Onboarding redesign,Desktop app";
// Progress 0, 0, 0.2, 0.35, 0.62; equal progress falls back to the name in both directions.
const PROGRESS_ASC = "Onboarding redesign,Search revamp,Public API,Sync engine v2,Desktop app";
const PROGRESS_DESC = "Desktop app,Sync engine v2,Public API,Onboarding redesign,Search revamp";

const projectFilter = (statusTypes) => ({ and: [{ status: { type: { in: statusTypes } } }] });

// The project page's Issues tab: the project AND the view's state types (model.projectIssueFilter).
const ACTIVE_TYPES = ["triage", "unstarted", "started"];
const projectIssueFilter = (projectId, stateTypes) => ({
	and: [{ project: { id: { eq: projectId } } }, { state: { type: { in: stateTypes } } }],
});
// Desktop app's Active issues in board order: Todo, then In Progress; by priority, then manual order.
const DESKTOP_ACTIVE = "ENG-139,ENG-146,DES-15,ENG-142,ENG-140,ENG-138,ENG-131,DES-12";
// Its table by priority: ties by identifier (team key, number) in both directions.
const PRIORITY_ASC = "ENG-142,ENG-138,ENG-139,ENG-140,DES-12,ENG-131,ENG-146,DES-15";
const PRIORITY_DESC = "DES-15,DES-12,ENG-131,ENG-146,ENG-138,ENG-139,ENG-140,ENG-142";
// Its milestone filter (model.projectIssueFilter with a milestone): the project, the milestone, then the view.
const milestoneIssueFilter = (projectId, milestoneId, stateTypes) => ({
	and: [{ project: { id: { eq: projectId } } }, { projectMilestone: { id: { eq: milestoneId } } }, { state: { type: { in: stateTypes } } }],
});
const milestoneNamed = (projectName, name) =>
	mock.state().projectMilestones.find((m) => m.projectId === projectNamed(projectName).id && m.name === name);
// Desktop app's Beta issues in board order: Active (Todo, In Progress), Backlog, and All (Backlog first).
const BETA_ACTIVE = "DES-15,ENG-142,ENG-138";
const BETA_ALL = "ENG-150,DES-15,ENG-142,ENG-138";
/** The filter of the newest `Issues` request since `before`, as JSON (for exact comparisons). */
const lastIssuesFilter = (before) => JSON.stringify(opsSince(before, "Issues").at(-1)?.variables.filter);
// Card and row texts run the identifier into the next word ("ENG-139High…"), so no trailing word boundary.
const ISSUE_ID = /\b[A-Z]+-\d+/;

/** Issue identifiers of the board's cards, in board order. */
const cardIds = async () => (await nodesOf(role("card"))).map((node) => ISSUE_ID.exec(node.text ?? "")?.[0]).join(",");

/** Issue identifiers of the table's rows, top to bottom. */
const tableIds = async () =>
	(await nodesOf(`${role("table")} .sf-tbl-row:not(.head)`)).map((node) => ISSUE_ID.exec(node.text ?? "")?.[0]).join(",");

/** Board column titles, left to right (the head's text minus its count). */
const columnTitles = async () =>
	(await nodesOf(role("column-head"))).map((node) => (node.text ?? "").replace(/\d+$/, "")).join(",");

/** Project card names in board order. */
const projectCards = async () =>
	(await nodesOf(`${role("project-card")} ${role("card-title")}`)).map((node) => node.text).join(",");

/** Project names in table row order. */
async function tableOrder() {
	const names = mock.state().projects.map((project) => project.name);
	const rows = (await nodesOf(`${role("table")} .sf-tbl-row:not(.head)`)).map((node) => node.text ?? "");
	return rows.map((text) => names.find((name) => text.startsWith(name)) ?? text).join(",");
}

/** The label of the focused pane (a web pane opened by `o` is labelled with the site's host). */
const focusedLabel = async () => (await t.ctl("state")).focused?.label ?? "";

const SELECTED_CARD = `${role("project-card")}[data-mark='selected']`;
const projectNamed = (name) => mock.state().projects.find((project) => project.name === name);
// Linear's milestone order is the sortOrder; the mock sends milestones highest sortOrder first.
const DESKTOP_MILESTONES = "Alpha,Beta,Accessibility audit,Public launch";

/** Milestone names on the project page, top to bottom. */
const milestoneNames = async () =>
	(await nodesOf(`${role("milestone")} ${role("milestone-name")}`)).map((node) => node.text).join(",");

/** Waits for the project page of `name` with its detail loaded (the description or its empty state shows). */
async function pageOpen(name) {
	await present(role("project-header"));
	await t.waitFor(role("project-name"), name);
	await waitFor(async () => (await t.wait(150), (await exists(role("project-description"))) || exists(role("project-description-empty"))), {
		what: `the detail of ${name}`,
		interval: 0,
	});
}

// The Activity tab of Desktop app, newest first: [kind, text the row contains]. The fixture's unknown kind
// (`externalSync`), its entry with a string `at` and its empty record never show.
const DESKTOP_ACTIVITY = [
	["event", "ada changed the icon"],
	["event", "ada updated the summary"],
	["event", "grace changed the lead team from Engineering to Design"],
	["event", "grace renamed the project from Desktop client to Desktop app"],
	["update", "Beta is feature-complete"],
	["event", "ada and grace updated the description"],
	["event", "Milestone Alpha completed"],
	["update", "The accessibility audit found two"],
	["update", "Signing certificates expired"],
	["event", "ada added team Design"],
	["event", "grace added milestones Alpha and Beta"],
	["event", "ada set the start date to"],
	["event", "ada changed status from Planned to In Progress"],
];

const ACTIVITY_ITEMS = `${role("activity-update")}, ${role("activity-event")}`;

/** The Activity tab's rows, top to bottom: `{ kind, text }` (the tree carries no roles; update texts tell them apart). */
async function activityRows() {
	const updates = new Set((await nodesOf(role("activity-update"))).map((node) => node.text));
	return (await nodesOf(ACTIVITY_ITEMS)).map((node) => ({ kind: updates.has(node.text) ? "update" : "event", text: node.text ?? "" }));
}

/** Opens the Activity tab by clicking it and waits until it shows its items or its empty state. */
async function openActivity() {
	await t.click(role("project-tab-activity"));
	await present(role("activity"));
	await waitFor(async () => (await t.wait(150), (await exists(ACTIVITY_ITEMS)) || exists(role("activity-empty"))), {
		what: "the Activity tab to load",
		interval: 0,
	});
}

/** Leaves the project page with Escape; the list is back with `name` selected. */
async function backToList(name) {
	await t.key("Escape");
	await absent(role("project-header"));
	await present(role("bar"));
	if (name) await t.waitFor(SELECTED_CARD, name);
}

let operations = []; // operation names the mock saw before the README run reset it
let opened; // identifier of the issue the drawer showed in step 8
let created; // the issue created in step 12

async function scenario() {
	await runner.step("open-setup", async (label) => {
		await t.openBlock();
		await see("Connect Linear");
		await present(role("setup-key"));
		await runner.shot(label);
		await runner.shot("readme-setup");
	});

	await runner.step("invalid-key", async (label) => {
		await t.type(BAD_KEY);
		await t.key("Enter");
		await see("doesn't look like");
		assertEqual(mock.log.filter((entry) => entry.status === 200).length, 0, "requests answered before a valid key");
		await runner.shot(label);
	});

	// A fresh block opens in projects mode: no issue is requested until the operator switches to Issues.
	await runner.step("valid-key-projects", async (label) => {
		await backspaces(BAD_KEY.length + 8);
		await t.type(mock.apiKey);
		const before = mark();
		await t.key("Enter");
		await see("Desktop app");
		for (const name of ["Viewer", "Teams", "ProjectStatuses", "Projects"]) {
			if (opsSince(before, name).length === 0) throw new Error(`no ${name} request`);
		}
		assertEqual(opsSince(before, "Issues").length, 0, "Issues requests in projects mode");
		const [first] = opsSince(before, "Projects");
		assertEqual(JSON.stringify(first.variables.filter), JSON.stringify(projectFilter(["planned", "started", "paused"])), "first project filter");
		await present(role("board"));
		assertEqual(await columnTitles(), "Planned,In Progress,Paused", "active project columns");
		assertEqual(await projectCards(), ACTIVE_PROJECTS, "active project cards");
		const text = await t.text();
		for (const hidden of ["Docs site refresh", "Retired status", "New issue"]) {
			if (text.includes(hidden)) throw new Error(`projects board shows ${JSON.stringify(hidden)}`);
		}
		await t.waitFor(role("search"), "Search projects");
		await t.waitFor(role("team-select"), "All projects");
		await runner.shot(label);
		await runner.shot("projects-board");
	});

	await runner.step("projects-views", async (label) => {
		let before = mark();
		await t.key("3");
		await see("Billing migration");
		await see("Legacy importer");
		assertEqual(await columnTitles(), "Backlog,Planned,In Progress,Paused,Completed,Canceled", "all-view columns");
		const all = opsSince(before, "Projects").at(-1);
		if (all.variables?.filter !== undefined) throw new Error(`the all view filters projects: ${JSON.stringify(all.variables.filter)}`);
		await runner.shot(label);
		before = mark();
		await t.key("2");
		await see("Mobile companion");
		await gone("Desktop app");
		assertEqual(await columnTitles(), "Backlog", "backlog-view columns");
		assertEqual(JSON.stringify(opsSince(before, "Projects").at(-1).variables.filter), JSON.stringify(projectFilter(["backlog"])), "backlog filter");
		await t.key("1");
		await see("Desktop app");
		await gone("Mobile companion");
	});

	await runner.step("projects-scope", async (label) => {
		let before = mark();
		await t.key("m");
		await t.waitFor(role("team-select"), "My projects");
		await gone("Sync engine v2");
		await see("Onboarding redesign");
		assertEqual(await projectCards(), MY_PROJECTS, "my projects");
		if (!JSON.stringify(opsSince(before, "Projects").at(-1).variables.filter).includes("isMe")) {
			throw new Error("My projects is not filtered on the viewer");
		}
		before = mark();
		await t.key("t");
		await t.waitFor(role("team-select"), "Engineering");
		await see("Sync engine v2");
		await gone("Onboarding redesign");
		if (!JSON.stringify(opsSince(before, "Projects").at(-1).variables.filter).includes("accessibleTeams")) {
			throw new Error("team scope is not filtered on accessible teams");
		}
		await runner.shot(label);
		await t.key("m");
		await t.waitFor(role("team-select"), "My projects");
		await t.key("m");
		await t.waitFor(role("team-select"), "All projects");
		await see("Sync engine v2");
		await see("Onboarding redesign");
	});

	await runner.step("projects-search", async (label) => {
		await search("sync");
		await see("Sync engine v2");
		await gone("Desktop app");
		await runner.shot(label);
		await clearSearch("sync".length);
		await see("Desktop app");
	});

	await runner.step("projects-table-sort", async (label) => {
		await t.key("v");
		await present(role("table"));
		await t.waitFor(role("table"), "Desktop app");
		await t.click(role("sort-progress"));
		await waitFor(async () => (await t.wait(150), (await tableOrder()) === PROGRESS_ASC), {
			what: `the table sorted by progress (${PROGRESS_ASC})`,
			interval: 0,
		});
		await t.click(role("sort-progress"));
		await waitFor(async () => (await t.wait(150), (await tableOrder()) === PROGRESS_DESC), {
			what: `the table sorted by progress, descending (${PROGRESS_DESC})`,
			interval: 0,
		});
		await t.waitFor(role("sort-progress"), "↓");
		await runner.shot(label);
		await runner.shot("projects-table");
		await t.key("v");
		await present(role("board"));
	});

	// Headless Tern runs timers on app time: `wait` past the 30 s poll interval triggers the change check.
	await runner.step("projects-poll", async () => {
		await settle();
		const before = mark();
		await t.wait(31_000);
		const check = await waitFor(() => opsSince(before, "ProjectsChanged")[0], { what: "a ProjectsChanged poll" });
		if (!JSON.stringify(check.variables.filter).includes("updatedAt")) {
			throw new Error(`the poll does not ask for newer projects: ${JSON.stringify(check.variables.filter)}`);
		}
		assertEqual(opsSince(before, "IssuesChanged").length, 0, "issue polls in projects mode");
	});

	// The project page. Board order of the Active view: Search revamp, Onboarding redesign, Sync engine v2, Desktop app.
	await runner.step("project-page-enter", async (label) => {
		await t.key("Escape");
		await absent(SELECTED_CARD);
		for (let i = 0; i < 4; i += 1) await t.key("j");
		await t.waitFor(SELECTED_CARD, "Desktop app");
		const before = mark();
		await t.key("Enter");
		await pageOpen("Desktop app");
		const [detail] = opsSince(before, "Project");
		if (!detail) throw new Error("no Project request");
		assertEqual(detail.variables.id, projectNamed("Desktop app").id, "project requested");
		for (const listOnly of ["bar", "filters", "board", "table"]) {
			if (await exists(role(listOnly))) throw new Error(`the project page shows linear.${listOnly}`);
		}
		await t.waitFor(role("project-status"), "In Progress");
		await t.waitFor(role("project-header"), "On track");
		await present(role("project-open-url"));
		await present(role("project-refresh"));
		const tabs = await nodesOf(`${role("project-tabs")} [data-role^='linear.project-tab-']`);
		assertEqual(tabs.map((node) => node.text).join(","), "Overview,Activity,Issues", "project tabs");
		// The activity loads when its tab is first shown, not with the Overview.
		await settle();
		for (const op of ["ProjectUpdates", "ProjectHistory"]) assertEqual(opsSince(before, op).length, 0, `${op} before the Activity tab`);

		await t.waitFor(role("project-summary"), "The native desktop client");
		const doc = await t.text(role("project-description"));
		for (const part of ["Why", "Tray icon with unread counts", "design spec", "old prototype"]) {
			if (!doc.includes(part)) throw new Error(`the description lacks ${JSON.stringify(part)}: ${doc.slice(0, 300)}`);
		}
		// The sanitizer ran: the https link stays a link, the image is a link instead, the javascript: link is text.
		const links = (await nodesOf(`${role("project-description")} a`)).map((node) => node.text).join(",");
		assertEqual(links, "design spec,🖼 tray wireframe", "links of the project document");
		if (await exists(`${role("project-description")} img`)) throw new Error("the project document renders an image");
		assertEqual(await milestoneNames(), DESKTOP_MILESTONES, "milestones in Linear's order");
		const rows = (await nodesOf(role("milestone"))).map((node) => node.text ?? "");
		const row = (name) => rows.find((text) => text.includes(name)) ?? "";
		for (const [name, parts] of [
			["Alpha", ["Done", "100%"]],
			["Beta", ["Next", "45%"]],
			["Accessibility audit", ["Overdue", "30%"]],
			["Public launch", ["Not started", "0%"]],
		]) {
			for (const part of parts) if (!row(name).includes(part)) throw new Error(`milestone ${name} lacks ${part}: ${row(name)}`);
		}
		const props = await t.text(role("project-props"));
		for (const part of ["Lead", "ada", "Members", "ada, grace", "Engineering, Design", "High", "62%", "updated 3d ago", "Platform", "Customer request"]) {
			if (!props.includes(part)) throw new Error(`the properties lack ${JSON.stringify(part)}: ${props.slice(0, 400)}`);
		}
		if (props.includes("Initiatives")) throw new Error("the properties show a group label");
		await present(`${role("project-overview")}[data-mark='wide']`);
		await runner.shot(label);
		await runner.shot("project-overview");

		// A narrow pane stacks the properties above the content.
		await t.ctl("size 760 900");
		await present(`${role("project-overview")}[data-mark='stacked']`);
		await runner.shot("project-overview-narrow");
		await t.ctl("size 1440 900");
		await present(`${role("project-overview")}[data-mark='wide']`);
	});

	// The Activity tab of Desktop app: updates and history events in one newest-first feed.
	await runner.step("project-activity", async (label) => {
		const desktop = projectNamed("Desktop app").id;
		let before = mark();
		await openActivity();
		for (const op of ["ProjectUpdates", "ProjectHistory"]) {
			const [request] = opsSince(before, op);
			if (!request) throw new Error(`no ${op} request when the Activity tab opened`);
			assertEqual(request.variables.id, desktop, `${op} project`);
			assertEqual(request.variables.after ?? null, null, `${op} first page`);
		}
		await waitFor(async () => (await t.wait(150), (await activityRows()).length === DESKTOP_ACTIVITY.length), {
			what: `${DESKTOP_ACTIVITY.length} activity rows`,
			interval: 0,
		});
		const rows = await activityRows();
		DESKTOP_ACTIVITY.forEach(([kind, text], i) => {
			if (rows[i].kind !== kind || !rows[i].text.includes(text)) {
				throw new Error(`activity row ${i + 1}: expected ${kind} "${text}", got ${rows[i].kind} "${rows[i].text}"`);
			}
		});
		const all = rows.map((row) => row.text).join("\n");
		for (const hidden of ["externalSync", "github", "yesterday", "Backlog to Planned", "{"]) {
			if (all.includes(hidden)) throw new Error(`the activity shows an unknown or malformed entry (${hidden})`);
		}
		for (const health of ["onTrack", "atRisk", "offTrack"]) await present(`${role("activity-update")}[data-mark='${health}']`);
		await t.waitFor(`${role("activity-update")}[data-mark='offTrack']`, "Off track");
		const body = await t.text(`${role("activity-update")}[data-mark='onTrack'] ${role("activity-body")}`);
		for (const part of ["Beta is feature-complete", "Tray icon shipped", "release checklist"]) {
			if (!body.includes(part)) throw new Error(`the update body lacks ${JSON.stringify(part)}: ${body}`);
		}
		if (body.includes("**")) throw new Error(`the update body shows raw Markdown: ${body}`);
		assertEqual((await nodesOf(role("activity-edited"))).length, 1, "edited markers");
		await present(`${role("activity-update")}[data-mark='atRisk'] ${role("activity-edited")}`);
		if (await exists(role("activity-more"))) throw new Error("Load more on a project whose activity fits one page");

		// The comment count expands the update's comments, oldest first, and collapses them again.
		await t.waitFor(role("activity-comments-toggle"), "2 comments");
		await t.click(role("activity-comments-toggle"));
		await waitFor(async () => (await t.wait(150), (await nodesOf(role("activity-comment"))).length === 2), {
			what: "two update comments",
			interval: 0,
		});
		const comments = (await nodesOf(role("activity-comment"))).map((node) => node.text ?? "");
		if (!comments[0].includes("Which screens fail?") || !comments[1].includes("Settings and onboarding")) {
			throw new Error(`update comments out of order: ${comments.join(" | ")}`);
		}
		await runner.shot(label);
		await t.click(role("activity-comments-toggle"));
		await absent(role("activity-comment"));

		// `tab` / `shift+tab` cycle the tabs (Overview, Activity, Issues, wrapping); a loaded Activity tab does not
		// reload when shown again. The Issues tab stays unvisited here: its lazy load is checked later. Right after a
		// poll tick, so the next one stays out of this check and the `r` one below.
		await afterPageTick();
		before = mark();
		await t.key("Shift+Tab");
		await present(role("project-overview"));
		await t.key("Tab");
		await present(role("activity-update"));
		await t.wait(300);
		assertEqual(opsSince(before, "ProjectUpdates").length, 0, "activity reloads when the tab shows again");

		// `r` reloads the tab on screen only.
		await settle();
		before = mark();
		await t.key("r");
		await waitFor(() => opsSince(before, "ProjectUpdates").length > 0 && opsSince(before, "ProjectHistory").length > 0, {
			what: "an activity reload after r",
		});
		assertEqual(opsSince(before, "Project").length, 0, "detail reloads from r on the Activity tab");

		// The poll tick reloads the activity while its tab shows, and the detail beside it ...
		await settle();
		before = mark();
		await t.wait(31_000);
		await waitFor(() => opsSince(before, "ProjectUpdates").length > 0, { what: "an activity reload on the poll tick" });
		await waitFor(() => opsSince(before, "Project").length > 0, { what: "a detail reload on the poll tick" });
		await present(role("activity-update"));
		// ... and not while the Overview shows.
		await t.click(role("project-tab-overview"));
		await present(role("project-overview"));
		await settle();
		before = mark();
		await t.wait(31_000);
		await waitFor(() => opsSince(before, "Project").length > 0, { what: "a detail reload on the poll tick" });
		assertEqual(opsSince(before, "ProjectUpdates").length, 0, "activity reloads while the Overview shows");
		await openActivity();
		await runner.shot("project-activity");
	});

	// Sync engine v2 has 24 updates: the first page holds 20, and its older status change waits for Load more.
	await runner.step("project-activity-more", async (label) => {
		await backToList("Desktop app");
		await t.key("k");
		await t.waitFor(SELECTED_CARD, "Sync engine v2");
		await t.key("Enter");
		await pageOpen("Sync engine v2");
		await openActivity();
		const updates = async () => (await nodesOf(role("activity-update"))).length;
		await waitFor(async () => (await t.wait(150), (await updates()) === 20), { what: "the first 20 updates", interval: 0 });
		if (await exists(role("activity-event"))) throw new Error("an event older than the loaded updates shows before Load more");
		await t.waitFor(role("activity-more"), "Load more");
		await runner.shot(label);
		await settle();
		const before = mark();
		await t.click(role("activity-more"));
		await waitFor(async () => (await t.wait(150), (await updates()) === 24), { what: "all 24 updates", interval: 0 });
		const [more] = opsSince(before, "ProjectUpdates");
		if (!more?.variables.after) throw new Error(`Load more did not page: ${JSON.stringify(more?.variables)}`);
		assertEqual(opsSince(before, "ProjectHistory").length, 0, "history pages without more");
		await absent(role("activity-more"));
		const rows = await activityRows();
		const last = rows[rows.length - 1];
		if (last.kind !== "event" || !last.text.includes("linus changed status from Planned to In Progress")) {
			throw new Error(`the oldest row is not the status change: ${JSON.stringify(last)}`);
		}
		await backToList("Sync engine v2");
		await t.key("j");
		await t.waitFor(SELECTED_CARD, "Desktop app");
		await t.key("Enter");
		await pageOpen("Desktop app");
	});

	await runner.step("project-page-keys", async () => {
		await t.click(role("project-tab-overview"));
		await t.key("Tab");
		await t.key("Shift+Tab");
		await present(role("project-overview"));
		await settle();
		const before = mark();
		for (const key of ["j", "k", "h", "l", "v", "1", "3", "m", "t", "/", "n", "x"]) await t.key(key);
		await t.wait(300);
		await present(role("project-header"));
		if (await exists(role("search"))) throw new Error("a list key closed the project page");
		assertEqual(opsSince(before, "Projects").length, 0, "list reloads from keys on the page");
		await t.key("y");
		await t.waitFor(role("notice"), "Copied link to Desktop app");
	});

	// The Issues tab of Desktop app: its issues (ENG and DES) on issues mode's board, table and drawer.
	await runner.step("project-issues-board", async (label) => {
		const desktop = projectNamed("Desktop app").id;
		await settle();
		assertEqual(mock.log.filter((entry) => entry.operationName === "Issues").length, 0, "Issues requests before the Issues tab");
		const before = mark();
		await t.click(role("project-tab-issues"));
		await present(role("project-issues"));
		await present(`${role("project-issues")} ${role("board")}`);
		const [load] = opsSince(before, "Issues");
		if (!load) throw new Error("no Issues request when the Issues tab opened");
		assertEqual(JSON.stringify(load.variables.filter), JSON.stringify(projectIssueFilter(desktop, ACTIVE_TYPES)), "Issues tab filter");
		assertEqual(await columnTitles(), "Triage,Todo,In Progress", "Issues tab columns (one per state type)");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), {
			what: `the project's issues on the board (${DESKTOP_ACTIVE})`,
			interval: 0,
		});
		const cards = await nodesOf(role("card"));
		const card = (id) => cards.find((node) => (node.text ?? "").includes(id))?.text ?? "";
		if (!card("ENG-146").includes("Blocked")) throw new Error(`ENG-146 shows no Blocked badge: ${card("ENG-146")}`);
		if (card("ENG-140").includes("Blocked")) throw new Error("ENG-140 is not blocked");
		for (const part of ["DES-12", "Redesign empty states", "ada", "UI", "Medium"]) {
			if (!card("DES-12").includes(part)) throw new Error(`the DES-12 card lacks ${part}: ${card("DES-12")}`);
		}
		await t.waitFor(`${role("project-issues")} ${role("count")}`, "8 issues");
		await t.waitFor(`${role("project-issues")} ${role("search")}`, "Search issues");
		await present(`${role("project-issues-bar")} ${role("view-active")}`);
		await present(`${role("project-issues")} ${role("filters")} ${role("filter-assignee")}`);
		if (await exists(role("bar"))) throw new Error("the Issues tab shows the list's top bar");
		if (await exists(role("drawer"))) throw new Error("a drawer before any issue was opened");
		await runner.shot(label);
		await runner.shot("project-issues-board");
	});

	await runner.step("project-issues-views-search", async (label) => {
		const desktop = projectNamed("Desktop app").id;
		let before = mark();
		await t.key("3");
		await see("Upgrade build tooling to Node 22");
		const all = opsSince(before, "Issues").at(-1).variables.filter;
		if (all.and[0].project?.id?.eq !== desktop || !all.and[1].or) throw new Error(`All view filter: ${JSON.stringify(all)}`);
		assertEqual(await columnTitles(), "Triage,Backlog,Todo,In Progress,Done,Canceled", "All view columns");
		before = mark();
		await t.key("2");
		await see("Evaluate Tauri for the desktop shell");
		await gone("Crash when opening large workspace");
		assertEqual(
			JSON.stringify(opsSince(before, "Issues").at(-1).variables.filter),
			JSON.stringify(projectIssueFilter(desktop, ["backlog"])),
			"Backlog view filter",
		);
		await t.key("1");
		await see("Crash when opening large workspace");
		await gone("Evaluate Tauri for the desktop shell");

		// The tab's search is its own: it filters the tab's list only.
		await search("icon");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === "DES-15"), { what: "only DES-15 to match", interval: 0 });
		await t.waitFor(`${role("project-issues")} ${role("count")}`, "1 issue");
		await present(role("clear-filters"));
		await runner.shot(label);
		await t.click(role("clear-filters"));
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), { what: "the search cleared", interval: 0 });

		// The filter row: priority filters the tab's list; the assignee options are the members of every team the
		// project's issues belong to (ENG and DES), not of one team.
		await pick("filter-priority", "High");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === "ENG-139,ENG-140,ENG-138"), {
			what: "the High issues only",
			interval: 0,
		});
		await t.waitFor(`${role("project-issues")} ${role("count")}`, "3 issues");
		await t.click(role("filter-assignee"));
		await present(SELECT_MENU);
		const options = await t.text(SELECT_MENU);
		for (const name of ["Me", "Unassigned", "dieter", "grace", "linus"]) {
			if (!options.includes(name)) throw new Error(`the assignee filter lacks ${name}: ${options}`);
		}
		await t.click(role("filter-assignee"));
		await absent(SELECT_MENU);
		await present(role("project-issues"));
		await t.click(role("clear-filters"));
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), { what: "the filters cleared", interval: 0 });
	});

	await runner.step("project-issues-table", async (label) => {
		await t.key("v");
		await present(`${role("project-issues")} ${role("table")}`);
		await t.click(role("sort-priority"));
		await waitFor(async () => (await t.wait(150), (await tableIds()) === PRIORITY_ASC), {
			what: `the tab's table sorted by priority (${PRIORITY_ASC})`,
			interval: 0,
		});
		await t.click(role("sort-priority"));
		await waitFor(async () => (await t.wait(150), (await tableIds()) === PRIORITY_DESC), {
			what: `the tab's table sorted by priority, descending (${PRIORITY_DESC})`,
			interval: 0,
		});
		await runner.shot(label);
		await runner.shot("project-issues-table");
		// Activating a row opens the issue drawer over the page.
		await t.dblclick(`${role("table")} .sf-tbl-row:not(.head)`);
		await present(role("drawer"));
		await t.waitFor(role("drawer"), "Audit icon set for consistency");
		await present(role("project-header"));
		// One Escape per layer: a second one would clear the selection, a third go back to the list.
		await t.key("Escape");
		await absent(role("drawer"));
		await present(`${role("project-issues")} ${role("table")}`);
		await t.key("Escape");
		await present(role("project-issues"));
		await t.key("v");
		await present(`${role("project-issues")} ${role("board")}`);
	});

	// A card click opens the drawer over the page; its edits reload the tab's list, never issues mode's.
	await runner.step("project-issues-drawer", async (label) => {
		const viewerId = mock.state().viewerId;
		const issue = issueNamed("ENG-139");
		await t.click(role("card"));
		await present(role("drawer"));
		await t.waitFor(role("drawer"), "Drag cards between board columns");
		await present(role("project-header"));
		await t.waitFor(role("drawer"), "Comments");
		await runner.shot(label);
		await runner.shot("project-issues-drawer");

		let before = mark();
		await t.key("a");
		const assign = await waitFor(
			() => opsSince(before, "IssueUpdate").find((op) => "assigneeId" in (op.variables.input ?? {})),
			{ what: "an IssueUpdate with assigneeId" },
		);
		await waitFor(() => opsSince(before, "Issues").length > 0, { what: "the tab's list to reload after the edit" });
		await settle();
		assertEqual(assign.variables.input.assigneeId, viewerId, "assigneeId sent from the tab's drawer");
		assertEqual(issueById(issue.id).assigneeId, viewerId, "assignee stored by the mock");
		for (const op of opsSince(before, "Issues")) {
			if (!JSON.stringify(op.variables.filter).includes(projectNamed("Desktop app").id)) {
				throw new Error(`a mutation on the Issues tab reloaded another list: ${JSON.stringify(op.variables.filter)}`);
			}
		}
		if (opsSince(before, "Issue").length === 0) throw new Error("no drawer reload after the edit");
		await t.waitFor(role("notice"), "Assigned to you");
		await present(role("drawer"));

		// `]` moves by state type within the issue's team: Todo → ENG's first started state.
		before = mark();
		await t.key("]");
		const move = await waitFor(
			() => opsSince(before, "IssueUpdate").find((op) => "stateId" in (op.variables.input ?? {})),
			{ what: "an IssueUpdate with stateId" },
		);
		await settle();
		assertEqual(move.variables.input.stateId, teamState("ENG", "In Progress").id, "state after ]");
		const inProgress = async () =>
			(await nodesOf(role("column"))).find((node) => (node.text ?? "").includes("In Progress"))?.text ?? "";
		await waitFor(async () => (await t.wait(150), (await inProgress()).includes("ENG-139")), {
			what: "ENG-139 in the In Progress column",
			interval: 0,
		});

		// `[` steps back a state type and `a` again unassigns: ENG-139 is as the fixture had it for issues mode.
		before = mark();
		await t.key("[");
		await waitFor(() => opsSince(before, "IssueUpdate").find((op) => op.variables.input?.stateId === teamState("ENG", "Todo").id), {
			what: "an IssueUpdate back to Todo",
		});
		await settle();
		before = mark();
		await t.key("a");
		await waitFor(() => opsSince(before, "IssueUpdate").find((op) => op.variables.input?.assigneeId === null), {
			what: "an IssueUpdate unassigning ENG-139",
		});
		await settle();
		assertEqual(issueById(issue.id).stateId, issue.stateId, "ENG-139 back in Todo");
		assertEqual(issueById(issue.id).assigneeId, null, "ENG-139 unassigned again");

		// Escape: the edit form, then the drawer, then the selection, and only then back to the list.
		await t.key("e");
		await present(role("edit-form"));
		await t.key("Escape");
		await absent(role("edit-form"));
		await present(role("drawer"));
		await t.key("Escape");
		await absent(role("drawer"));
		await present(`${role("card")}[data-mark='selected']`);
		await present(role("project-header"));
		await t.key("Escape");
		await absent(`${role("card")}[data-mark='selected']`);
		await present(role("project-issues"));
		await t.key("Escape");
		await absent(role("project-header"));
		await t.waitFor(SELECTED_CARD, "Desktop app");
		await t.key("Enter");
		await pageOpen("Desktop app");
	});

	// The poll tick runs the tab's change check only while the Issues tab shows.
	await runner.step("project-issues-poll", async () => {
		const desktop = projectNamed("Desktop app").id;
		await t.click(role("project-tab-issues"));
		await present(`${role("project-issues")} ${role("board")}`);
		await settle();
		let before = mark();
		await t.wait(31_000);
		const check = await waitFor(() => opsSince(before, "IssuesChanged")[0], { what: "an IssuesChanged poll on the Issues tab" });
		const filter = JSON.stringify(check.variables.filter);
		if (!filter.includes(desktop) || !filter.includes("updatedAt")) throw new Error(`the tab's change check: ${filter}`);
		assertEqual(opsSince(before, "ProjectsChanged").length, 0, "list polls while the page is open");
		await t.click(role("project-tab-overview"));
		await present(role("project-overview"));
		await settle();
		before = mark();
		await t.wait(31_000);
		await waitFor(() => opsSince(before, "Project").length > 0, { what: "a detail reload on the poll tick" });
		assertEqual(opsSince(before, "IssuesChanged").length, 0, "issue polls while the Overview shows");
		assertEqual(opsSince(before, "Issues").length, 0, "issue reloads while the Overview shows");
	});

	// A page saved on its Issues tab comes back on that tab and loads its issues.
	await runner.step("project-issues-restore", async (label) => {
		const desktop = projectNamed("Desktop app").id;
		await t.click(role("project-tab-issues"));
		await present(`${role("project-issues")} ${role("board")}`);
		await settle();
		const before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Viewer").length > 0, { what: "the block to restart" });
		await present(role("project-header"));
		await present(`${role("project-issues")} ${role("board")}`);
		const [load] = opsSince(before, "Issues");
		if (!load || !JSON.stringify(load.variables.filter).includes(desktop)) {
			throw new Error(`no project Issues request after restoring the Issues tab: ${JSON.stringify(load?.variables)}`);
		}
		await t.waitFor(role("card"), "Drag cards between board columns");
		await runner.shot(label);
		await runner.shot("project-issues-restore");
		await t.click(role("project-tab-overview"));
		await present(role("project-overview"));
	});

	// A milestone row of the Overview shows the Issues tab filtered to that milestone (layer 5).
	await runner.step("project-milestone-click", async (label) => {
		const desktop = projectNamed("Desktop app").id;
		const beta = milestoneNamed("Desktop app", "Beta").id;
		// Unfiltered, the cards and the table name each issue's milestone; the select offers All milestones.
		await t.click(role("project-tab-issues"));
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), { what: "the unfiltered tab", interval: 0 });
		await t.waitFor(role("milestone-filter"), "All milestones");
		const cards = await nodesOf(role("card"));
		const card = (id) => cards.find((node) => (node.text ?? "").includes(id))?.text ?? "";
		if (!card("DES-12").includes("◆ Accessibility audit")) throw new Error(`DES-12 shows no milestone: ${card("DES-12")}`);
		if (!card("ENG-142").includes("◆ Beta")) throw new Error(`ENG-142 shows no milestone: ${card("ENG-142")}`);
		if (card("ENG-131").includes("◆")) throw new Error(`ENG-131 has no milestone but shows one: ${card("ENG-131")}`);
		await t.key("v");
		await present(`${role("project-issues")} ${role("table")}`);
		await t.waitFor(`${role("table")} .sf-tbl-row.head`, "Milestone");
		await t.waitFor(role("table"), "Accessibility audit");
		await t.key("v");
		await present(`${role("project-issues")} ${role("board")}`);

		await t.click(role("project-tab-overview"));
		await present(role("project-overview"));
		await settle();
		const before = mark();
		await t.click(`${role("milestone")}[data-mark='next']`);
		await present(role("project-issues"));
		await waitFor(() => opsSince(before, "Issues").length > 0, { what: "an Issues request after the milestone click" });
		assertEqual(lastIssuesFilter(before), JSON.stringify(milestoneIssueFilter(desktop, beta, ACTIVE_TYPES)), "milestone filter");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ACTIVE), {
			what: `Beta's Active issues (${BETA_ACTIVE})`,
			interval: 0,
		});
		await t.waitFor(`${role("project-issues")} ${role("count")}`, "3 issues");
		await t.waitFor(role("milestone-filter"), "Beta");
		await present(`${role("milestone-filter")}[data-mark='active']`);
		// Every card is Beta's: the cards leave the milestone out.
		if ((await t.text(role("board"))).includes("◆")) throw new Error("filtered cards repeat the milestone");
		await runner.shot(label);
		await runner.shot("project-issues-milestone");
	});

	// The view switch and the search keep the milestone; Clear filters clears the client filters only.
	await runner.step("project-milestone-views", async () => {
		const desktop = projectNamed("Desktop app").id;
		const beta = milestoneNamed("Desktop app", "Beta").id;
		let before = mark();
		await t.key("2");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === "ENG-150"), { what: "Beta's Backlog issue", interval: 0 });
		assertEqual(lastIssuesFilter(before), JSON.stringify(milestoneIssueFilter(desktop, beta, ["backlog"])), "Backlog view filter");
		before = mark();
		await t.key("3");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ALL), { what: `Beta's issues (${BETA_ALL})`, interval: 0 });
		const all = opsSince(before, "Issues").at(-1).variables.filter;
		if (all.and[1].projectMilestone?.id?.eq !== beta || !all.and[2].or) throw new Error(`All view filter: ${JSON.stringify(all)}`);
		await t.key("1");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ACTIVE), { what: "Beta's Active issues", interval: 0 });
		await search("icon");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === "DES-15"), { what: "only DES-15 to match", interval: 0 });
		await t.click(role("clear-filters"));
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ACTIVE), { what: "the search cleared", interval: 0 });
		await t.waitFor(role("milestone-filter"), "Beta");
	});

	// The poll's change check carries the milestone too.
	await runner.step("project-milestone-poll", async () => {
		const beta = milestoneNamed("Desktop app", "Beta").id;
		await settle();
		const before = mark();
		await t.wait(31_000);
		const check = await waitFor(() => opsSince(before, "IssuesChanged")[0], { what: "an IssuesChanged poll on the filtered tab" });
		const filter = JSON.stringify(check.variables.filter);
		if (!filter.includes(`"projectMilestone":{"id":{"eq":"${beta}"}}`) || !filter.includes("updatedAt")) {
			throw new Error(`the filtered tab's change check: ${filter}`);
		}
		for (const op of opsSince(before, "Issues")) {
			if (!JSON.stringify(op.variables.filter).includes(beta)) throw new Error(`a poll reload dropped the milestone: ${JSON.stringify(op.variables.filter)}`);
		}
		await t.waitFor(role("milestone-filter"), "Beta");
	});

	// The filter is saved with the page: a restored block reopens the tab filtered; a milestone deleted meanwhile is
	// dropped with a notice and the tab reloads unfiltered.
	await runner.step("project-milestone-restore", async (label) => {
		const beta = milestoneNamed("Desktop app", "Beta").id;
		await settle();
		let before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Viewer").length > 0, { what: "the block to restart" });
		await present(role("project-issues"));
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ACTIVE), { what: "the restored filtered tab", interval: 0 });
		const [load] = opsSince(before, "Issues");
		if (!load || load.variables.filter.and[1].projectMilestone?.id?.eq !== beta) {
			throw new Error(`the restored tab's first load is not filtered: ${JSON.stringify(load?.variables)}`);
		}
		await t.waitFor(role("milestone-filter"), "Beta");

		// Public launch holds no issue: the select picks it, the empty state shows; then Linear deletes it.
		const launch = milestoneNamed("Desktop app", "Public launch").id;
		before = mark();
		await pick("milestone-filter", "Public launch");
		await present(`${role("project-issues")} ${role("empty")}`);
		if (!lastIssuesFilter(before).includes(launch)) throw new Error(`the select sent no milestone filter: ${lastIssuesFilter(before)}`);
		await settle();
		mock.deleteMilestone(launch);
		before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Viewer").length > 0, { what: "the block to restart" });
		await t.waitFor(role("notice"), "Milestone not found");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), { what: "the unfiltered tab", interval: 0 });
		if (lastIssuesFilter(before).includes("projectMilestone")) throw new Error(`still filtered: ${lastIssuesFilter(before)}`);
		await t.waitFor(role("milestone-filter"), "All milestones");
		await runner.shot(label);
	});

	// "All milestones" clears the filter; Back clears it too, so the page reopens unfiltered.
	await runner.step("project-milestone-clear-back", async () => {
		const desktop = projectNamed("Desktop app").id;
		await pick("milestone-filter", "Beta");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ACTIVE), { what: "Beta picked", interval: 0 });
		let before = mark();
		await pick("milestone-filter", "All milestones");
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), { what: "the filter cleared", interval: 0 });
		assertEqual(lastIssuesFilter(before), JSON.stringify(projectIssueFilter(desktop, ACTIVE_TYPES)), "filter after All milestones");
		if (await exists(`${role("milestone-filter")}[data-mark='active']`)) throw new Error("the cleared select still shows as active");

		await t.click(role("project-tab-overview"));
		await present(`${role("milestone")}[data-mark='next']`);
		await t.click(`${role("milestone")}[data-mark='next']`);
		await waitFor(async () => (await t.wait(150), (await cardIds()) === BETA_ACTIVE), { what: "Beta from the Overview", interval: 0 });
		await backToList("Desktop app");
		await t.key("Enter");
		await pageOpen("Desktop app");
		await settle();
		before = mark();
		await t.click(role("project-tab-issues"));
		await waitFor(async () => (await t.wait(150), (await cardIds()) === DESKTOP_ACTIVE), { what: "the reopened tab unfiltered", interval: 0 });
		assertEqual(lastIssuesFilter(before), JSON.stringify(projectIssueFilter(desktop, ACTIVE_TYPES)), "filter after Back");
		await t.waitFor(role("milestone-filter"), "All milestones");
		await t.click(role("project-tab-overview"));
		await present(role("project-overview"));
	});

	await runner.step("project-page-back", async (label) => {
		await backToList("Desktop app");
		await present(role("board"));
		assertEqual(await columnTitles(), "Planned,In Progress,Paused", "columns after Back");
		await t.waitFor(role("team-select"), "All projects");
		await runner.shot(label);
		await runner.shot("project-back-list");

		// A card click opens the page; the Back button and Backspace return to the list.
		await t.click(SELECTED_CARD);
		await pageOpen("Desktop app");
		await t.click(role("project-back"));
		await absent(role("project-header"));
		await t.waitFor(SELECTED_CARD, "Desktop app");
		await t.key("Enter");
		await pageOpen("Desktop app");
		await t.key("Backspace");
		await absent(role("project-header"));
		await t.waitFor(SELECTED_CARD, "Desktop app");
	});

	await runner.step("project-page-empty", async (label) => {
		await t.key("v");
		await present(role("table"));
		await search("onboarding");
		await waitFor(async () => (await t.wait(150), (await tableOrder()) === "Onboarding redesign"), {
			what: "the table filtered to Onboarding redesign",
			interval: 0,
		});
		// The selection (Desktop app) is hidden by the search: Enter opens nothing.
		const hidden = mark();
		await t.key("Enter");
		await t.wait(300);
		if ((await exists(role("project-header"))) || opsSince(hidden, "Project").length > 0) {
			throw new Error("Enter opened a project the search hides");
		}
		// Activating a table row (double-click) opens the page.
		await t.dblclick(`${role("table")} .sf-tbl-row:not(.head)`);
		await pageOpen("Onboarding redesign");
		await t.waitFor(role("project-description-empty"), "No description");
		await t.waitFor(role("milestones-empty"), "No milestones");
		await t.waitFor(role("project-props"), "No update");
		// A quarter-precision target date reads as its quarter, not as a day.
		const [year, month] = projectNamed("Onboarding redesign").targetDate.split("-").map(Number);
		await t.waitFor(role("project-props"), `Q${Math.floor((month - 1) / 3) + 1} ${year}`);
		await runner.shot(label);
		// A project without updates or history.
		await openActivity();
		await t.waitFor(role("activity-empty"), "No activity yet");
		if (await exists(ACTIVITY_ITEMS)) throw new Error("activity rows on a project without activity");
		await runner.shot("project-activity-empty");
		await t.key("Escape");
		await absent(role("project-header"));
		await present(role("table"));
		await clearSearch("onboarding".length);
		await t.key("v");
		await present(role("board"));
		await t.waitFor(SELECTED_CARD, "Onboarding redesign");
	});

	// While the page is open the poll tick reloads its detail; the list's change check pauses.
	await runner.step("project-page-poll", async () => {
		await t.key("Enter");
		await pageOpen("Onboarding redesign");
		await settle();
		const before = mark();
		await t.wait(31_000);
		await waitFor(() => opsSince(before, "Project").length > 0, { what: "a Project reload on the poll tick" });
		assertEqual(opsSince(before, "ProjectsChanged").length, 0, "list polls while the page is open");
		assertEqual(opsSince(before, "ProjectUpdates").length, 0, "activity polls while the Overview shows");
		await present(role("project-header"));
	});

	// `plugins fixtures` re-creates the block from `save`: the open page comes back.
	await runner.step("project-page-restore", async (label) => {
		await settle();
		const before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Viewer").length > 0, { what: "the block to restart" });
		await pageOpen("Onboarding redesign");
		if (opsSince(before, "Project").length === 0) throw new Error("no Project request after restoring the page");
		await runner.shot(label);

		// A page saved on its Activity tab comes back on that tab and loads its activity.
		await openActivity();
		await settle();
		const again = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(again, "Viewer").length > 0, { what: "the block to restart" });
		await present(role("project-header"));
		await t.waitFor(role("activity-empty"), "No activity yet");
		if (opsSince(again, "ProjectUpdates").length === 0) throw new Error("no ProjectUpdates request after restoring the Activity tab");
		if (await exists(role("project-overview"))) throw new Error("the restored page shows the Overview");
		await runner.shot("project-activity-restore");
		await backToList("Onboarding redesign");
	});

	await runner.step("project-page-notfound", async (label) => {
		await search("public");
		await t.key("j");
		await t.waitFor(SELECTED_CARD, "Public API");
		await t.key("Enter");
		await pageOpen("Public API");
		mock.deleteProject(projectNamed("Public API").id);
		await t.key("r");
		await absent(role("project-header"));
		await t.waitFor(role("notice"), "Project not found");
		// The deleted project leaves the list: the search now matches nothing, and Enter reopens nothing.
		await present(role("empty"));
		if (await exists(role("project-card"))) throw new Error("the deleted project is still on the board");
		const reopen = mark();
		await t.key("Enter");
		await t.wait(300);
		if ((await exists(role("project-header"))) || opsSince(reopen, "Project").length > 0) {
			throw new Error("Enter reopened the deleted project");
		}
		await runner.shot(label);
		await clearSearch("public".length);
	});

	// A rate-limited first Activity load only sets the banner: once no request is pending the tab shows no loading
	// line, and showing the tab again retries.
	await runner.step("project-activity-rate", async (label) => {
		await search("sync");
		await t.key("j");
		await t.waitFor(SELECTED_CARD, "Sync engine v2");
		await t.key("Enter");
		await pageOpen("Sync engine v2");
		await settle();
		// The backoff runs on the wall clock (`os.time`) while `t.wait` advances app time: 3 s keep the poll tick from
		// retrying during the checks below.
		mock.rateLimitNext("ProjectUpdates", 3);
		await t.click(role("project-tab-activity"));
		await t.waitFor(role("error"), "Rate limited by Linear");
		// No request is pending and nothing loaded: no loading line, no inline error, no rows (the empty tab draws nothing).
		await t.wait(500);
		if (await exists(role("activity-loading"))) throw new Error("the rate-limited Activity tab shows a loading line");
		if (await exists(role("activity-error"))) throw new Error("the rate limit shows in the Activity tab, not only the banner");
		if (await exists(ACTIVITY_ITEMS)) throw new Error("activity rows after a failed first load");
		await runner.shot(label);
		await t.click(role("project-tab-overview"));
		await present(role("project-overview"));
		await openActivity();
		await waitFor(async () => (await t.wait(150), (await nodesOf(role("activity-update"))).length === 20), {
			what: "the first 20 updates after the retry",
			interval: 0,
		});
		// The first poll tick past the backoff clears the banner.
		const failedAt = Date.now();
		while (await exists(role("error"))) {
			if (Date.now() - failedAt > 20_000) throw new Error("the rate limit banner stayed after the backoff");
			await t.wait(1000);
		}
		await backToList("Sync engine v2");
		await clearSearch("sync".length);
	});

	// A project deleted while its Activity tab is open leaves the list like one deleted under the Overview.
	await runner.step("project-activity-notfound", async (label) => {
		await t.key("3");
		await see("Mobile companion");
		await search("mobile");
		await t.key("j");
		await t.waitFor(SELECTED_CARD, "Mobile companion");
		await t.key("Enter");
		await pageOpen("Mobile companion");
		await openActivity();
		await settle();
		mock.deleteProject(projectNamed("Mobile companion").id);
		const before = mark();
		await t.key("r");
		await absent(role("project-header"));
		await t.waitFor(role("notice"), "Project not found");
		assertEqual(opsSince(before, "Project").length, 0, "detail reloads from r on the Activity tab");
		await present(role("empty"));
		if (await exists(role("project-card"))) throw new Error("the deleted project is still on the board");
		await runner.shot(label);
		await clearSearch("mobile".length);
		await t.key("1");
		await see("Desktop app");
	});

	await runner.step("project-page-restore-missing", async (label) => {
		await t.key("3");
		await see("Billing migration");
		await search("billing");
		await t.key("j");
		await t.waitFor(SELECTED_CARD, "Billing migration");
		await t.key("Enter");
		await pageOpen("Billing migration");
		await settle();
		mock.deleteProject(projectNamed("Billing migration").id);
		const before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Project").length > 0, { what: "the restored page's Project request" });
		await t.waitFor(role("notice"), "Project not found");
		await present(role("board"));
		if (await exists(role("project-header"))) throw new Error("the page of a missing project stayed open");
		await runner.shot(label);
		await t.key("1");
		await see("Desktop app");
	});

	// From here on the original issue scenario runs in issues mode.
	await runner.step("mode-issues", async (label) => {
		// The Issues tab never loaded issues mode's list: every Issues request so far was scoped to a project.
		for (const op of mock.log.filter((entry) => entry.operationName === "Issues")) {
			if (!JSON.stringify(op.variables.filter).includes('"project"')) throw new Error(`an unscoped Issues request: ${JSON.stringify(op.variables.filter)}`);
		}
		const before = mark();
		await t.key("i");
		await see("Crash when opening large workspace");
		const issues = opsSince(before, "Issues");
		if (issues.length === 0) throw new Error("no Issues request after switching to Issues");
		if (!JSON.stringify(issues[0].variables.filter).includes("isMe")) {
			throw new Error(`first board load is not scoped to my issues: ${JSON.stringify(issues[0].variables.filter)}`);
		}
		await t.waitFor(role("search"), "Search issues");
		// The Issues tab's search and filters stayed in the tab.
		await t.waitFor(role("filter-priority"), "Any priority");
		if (await exists(role("clear-filters"))) throw new Error("issues mode starts with filters from the Issues tab");
		await present(role("new"));
		await present(role("board"));
		await runner.shot(label);
	});

	await runner.step("view-all-and-back", async (label) => {
		await t.key("3");
		await see("Upgrade build tooling to Node 22");
		await runner.shot(label);
		await t.key("1");
		await gone("Upgrade build tooling to Node 22");
		await see("Crash when opening large workspace");
	});

	await runner.step("search", async (label) => {
		await t.key("/");
		await t.type("keyboard");
		await see("Add keyboard shortcuts to board");
		await gone("Crash when opening large workspace");
		await runner.shot(label);
		await t.key("Escape");
		await clearSearch("keyboard".length);
		await see("Crash when opening large workspace");
	});

	await runner.step("table-view", async (label) => {
		await t.key("v");
		await present(role("table"));
		// The Issues tab's priority sort stayed in the tab: issues mode's table is still newest first.
		await t.waitFor(role("sort-updated"), "↓");
		await see("Crash when opening large workspace");
		await runner.shot(label);
		await t.key("v");
		await present(role("board"));
		await absent(role("table"));
	});

	await runner.step("team-scope", async (label) => {
		const before = mark();
		await t.key("t");
		await see("Drag cards between board columns");
		await gone("Redesign empty states");
		await t.waitFor(role("team-select"), "Engineering");
		if (!opsSince(before, "Issues").some((op) => JSON.stringify(op.variables.filter).includes('"team"'))) {
			throw new Error("no team-scoped Issues request");
		}
		await runner.shot(label);
	});

	await runner.step("open-drawer", async (label) => {
		const before = mark();
		await t.key("Escape");
		await t.key("j");
		await t.key("Enter");
		await present(role("drawer"));
		await see("Comments");
		const drawer = await t.text(role("drawer"));
		opened = /\b(?:ENG|DES)-\d+\b/.exec(drawer)?.[0];
		if (!opened) throw new Error(`no issue identifier in the drawer: ${drawer.slice(0, 300)}`);
		if (!drawer.includes(issueNamed(opened).title)) throw new Error(`drawer for ${opened} does not show its title`);
		await waitFor(() => opsSince(before, "Issue").length > 0, { what: "the Issue detail request" });
		await runner.shot(label);
	});

	await runner.step("assign", async (label) => {
		const issue = issueNamed(opened);
		const viewerId = mock.state().viewerId;
		const before = mark();
		await t.key("a");
		const update = await waitFor(
			() => opsSince(before, "IssueUpdate").find((op) => "assigneeId" in (op.variables.input ?? {})),
			{ what: "an IssueUpdate with assigneeId" },
		);
		await settle();
		const expected = issue.assigneeId === viewerId ? null : viewerId;
		assertEqual(update.variables.input.assigneeId, expected, "assigneeId sent");
		assertEqual(issueById(issue.id).assigneeId, expected, "assignee stored by the mock");
		await runner.shot(label);
	});

	await runner.step("move-state", async (label) => {
		const issue = issueNamed(opened);
		const before = mark();
		await t.key("]");
		const update = await waitFor(
			() => opsSince(before, "IssueUpdate").find((op) => "stateId" in (op.variables.input ?? {})),
			{ what: "an IssueUpdate with stateId" },
		);
		await settle();
		if (update.variables.input.stateId === issue.stateId) throw new Error("the issue was not moved to another state");
		assertEqual(issueById(issue.id).stateId, update.variables.input.stateId, "state stored by the mock");
		await runner.shot(label);
	});

	await runner.step("comment", async (label) => {
		const issue = issueNamed(opened);
		const before = mark();
		await t.key("c");
		await t.type(COMMENT);
		await t.key("Ctrl+Enter");
		await see(COMMENT);
		const [call] = opsSince(before, "CommentCreate");
		if (!call) throw new Error("no CommentCreate request");
		assertEqual(call.variables.input.body, COMMENT, "comment body sent");
		const stored = mock.state().comments.filter((comment) => comment.issue === opened);
		assertEqual(stored.at(-1)?.body, COMMENT, "comment body stored by the mock");
		assertEqual(call.variables.input.issueId === issue.id || call.variables.input.issueId === opened, true, "comment target");
		await runner.shot(label);
	});

	// A comment typed on a project's Issues tab stays there: back in issues mode, reopening the drawer of the issue
	// selected there shows no draft and posts nothing.
	await runner.step("comment-draft-stays-on-tab", async () => {
		const DRAFT = "Draft for the tab's issue only";
		const selectedIssue = `${role("card")}[data-mark='selected']`;
		const selectedId = async () => ISSUE_ID.exec(await t.text(selectedIssue))?.[0];
		// Escape leaves the comment field, then closes the drawer; the selection stays (one more would clear it).
		await t.key("Escape");
		await t.wait(300);
		if (await exists(role("drawer"))) await t.key("Escape");
		await absent(role("drawer"));
		await t.waitFor(selectedIssue, opened);
		await t.key("p");
		await present(role("project-card"));
		await t.key("Escape");
		await absent(SELECTED_CARD);
		await t.key("j");
		for (let i = 0; i < 6 && !(await t.text(SELECTED_CARD)).includes("Desktop app"); i += 1) await t.key("j");
		await t.waitFor(SELECTED_CARD, "Desktop app");
		await t.key("Enter");
		await pageOpen("Desktop app");
		await t.click(role("project-tab-issues"));
		await present(`${role("project-issues")} ${role("board")}`);
		await t.key("j");
		await present(selectedIssue);
		if ((await selectedId()) === opened) await t.key("j");
		const tabIssue = await selectedId();
		if (!tabIssue || tabIssue === opened) throw new Error(`no tab issue other than ${opened} selected: ${tabIssue}`);
		await t.key("Enter");
		await present(role("drawer"));
		await t.waitFor(role("drawer"), issueNamed(tabIssue).title);
		await t.key("c");
		await t.type(DRAFT);
		await t.waitFor(role("comment-editor"), DRAFT);
		await t.key("Escape");

		await t.key("i");
		await absent(role("project-header"));
		await present(role("board"));
		await t.waitFor(selectedIssue, opened);
		await t.key("Enter");
		await present(role("drawer"));
		await t.waitFor(role("drawer"), issueNamed(opened).title);
		await see("Comments");
		if ((await t.text(role("comment-editor"))).includes(DRAFT)) throw new Error(`${opened}'s drawer shows the draft typed for ${tabIssue}`);
		const before = mark();
		await t.key("c");
		await t.key("Ctrl+Enter");
		await t.key("Escape");
		await settle();
		assertEqual(opsSince(before, "CommentCreate").length, 0, "comments posted after reopening the drawer");
	});

	await runner.step("create-issue", async (label) => {
		await closeDrawer();
		const before = mark();
		await t.key("n");
		await present(role("dialog"));
		await see("New issue");
		await t.type(NEW_TITLE);
		await t.waitFor(role("dialog"), NEW_TITLE);
		await t.key("Ctrl+Enter");
		await see(NEW_TITLE);
		await absent(role("dialog"));
		await t.waitFor(role("notice"), "Created");
		const call = opsSince(before, "IssueCreate")[0];
		if (!call) throw new Error("no IssueCreate request");
		assertEqual(call.variables.input.title, NEW_TITLE, "title sent");
		created = mock.state().issues.find((issue) => issue.title === NEW_TITLE);
		if (!created) throw new Error("the mock has no issue with the new title");
		const engineering = mock.state().teams.find((team) => team.key === "ENG");
		assertEqual(call.variables.input.teamId, engineering.id, "team of the new issue");
		await runner.shot(label);
	});

	await runner.step("mark-done", async (label) => {
		const before = mark();
		await search("E2E created");
		// A headless `click` right after typing is occasionally lost (seen on the untouched baseline too): retry it.
		for (let attempt = 0; attempt < 3 && !(await exists(role("drawer"))); attempt += 1) {
			if (attempt > 0) console.log("note: the card click was lost; clicking again");
			await t.click(role("card"));
			await waitFor(async () => (await t.wait(150), exists(role("drawer"))), { what: "the drawer", timeout: 3000, interval: 0 }).catch(() => {});
		}
		await present(role("drawer"));
		await t.key("x");
		const done = teamState("ENG", "Done");
		const update = await waitFor(
			() => opsSince(before, "IssueUpdate").find((op) => op.variables.input?.stateId === done.id),
			{ what: "an IssueUpdate moving the issue to Done" },
		);
		await settle();
		assertEqual(update.variables.id === created.id || update.variables.id === created.identifier, true, "updated issue");
		assertEqual(issueById(created.id).stateType, "completed", "state type stored by the mock");
		await closeDrawer();
		await clearSearch("E2E created".length);
		await t.key("3");
		await see(NEW_TITLE);
		await runner.shot(label);
		await t.key("1");
	});

	await runner.step("blocked-badge", async (label) => {
		await t.key("m");
		await see("Ship v2 export format");
		const cards = await nodesOf(role("card"));
		const blocked = cards.find((card) => (card.text ?? "").includes("Ship v2 export format"));
		if (!blocked || !blocked.text.includes("Blocked")) throw new Error("ENG-146 shows no Blocked badge");
		const unblocked = cards.find((card) => (card.text ?? "").includes("Fix flaky sync test on CI"));
		if (!unblocked || unblocked.text.includes("Blocked")) throw new Error("ENG-145 should not be blocked");
		await runner.shot(label);
		await t.key("2");
		await see("Document webhook retry policy");
		const backlog = await nodesOf(role("card"));
		const doc = backlog.find((card) => (card.text ?? "").includes("Document webhook retry policy"));
		if (doc?.text.includes("Blocked")) throw new Error("ENG-147 is blocked only by a completed issue and must not show Blocked");
		await t.key("1");
		await see("Crash when opening large workspace");
	});

	await runner.step("refresh", async (label) => {
		const before = mark();
		await t.key("r");
		await waitFor(() => opsSince(before, "Issues").length > 0, { what: "an Issues request after r" });
		await settle();
		await see("Crash when opening large workspace");
		await runner.shot(label);
	});

	// The edits above each ended in a background reload; the change check must still run afterwards.
	await runner.step("issues-poll", async () => {
		const before = mark();
		await t.wait(31_000);
		await waitFor(() => opsSince(before, "IssuesChanged").length > 0, { what: "an IssuesChanged poll after edits" });
		assertEqual(opsSince(before, "ProjectsChanged").length, 0, "project polls in issues mode");
	});

	// `plugins fixtures` reloads the fixture plugin: the block is re-created from what `save` returned.
	await runner.step("mode-restore", async (label) => {
		let before = mark();
		await t.key("p");
		await see("Desktop app");
		await waitFor(() => opsSince(before, "Projects").length > 0, { what: "a background Projects reload" });
		assertEqual(opsSince(before, "ProjectStatuses").length, 0, "status reloads when re-entering a loaded mode");
		await t.key("v");
		await present(role("table"));
		await settle();

		before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Viewer").length > 0, { what: "the block to restart" });
		await present(role("table"));
		await t.waitFor(role("table"), "Desktop app");
		await t.waitFor(role("mode-projects"), "Projects");
		await settle();
		if (opsSince(before, "Projects").length === 0) throw new Error("no Projects request after restoring projects mode");
		assertEqual(opsSince(before, "Issues").length, 0, "Issues requests after restoring projects mode");
		await runner.shot(label);

		await t.key("v");
		await present(role("board"));
		await t.key("i");
		await see("Crash when opening large workspace");
		await settle();
		before = mark();
		await t.ctl("plugins fixtures");
		await waitFor(() => opsSince(before, "Viewer").length > 0, { what: "the block to restart" });
		await see("Crash when opening large workspace");
		await settle();
		if (opsSince(before, "Issues").length === 0) throw new Error("no Issues request after restoring issues mode");
		assertEqual(opsSince(before, "Projects").length, 0, "Projects requests after restoring issues mode");

		before = mark();
		await t.key("p");
		await see("Desktop app");
		if (opsSince(before, "ProjectStatuses").length === 0) throw new Error("first entry into projects did not load the statuses");
		await present(role("project-card"));
	});

	// Last in this Tern: a successful `o` (here on the project page) opens a web pane that takes the focus.
	await runner.step("projects-select-open", async (label) => {
		const selected = `${role("project-card")}[data-mark='selected']`;
		await t.key("Escape");
		await absent(selected);
		await t.key("j");
		await t.waitFor(selected, "Search revamp");
		await t.key("j");
		await t.waitFor(selected, "Onboarding redesign");
		await t.key("l");
		await t.waitFor(selected, "Sync engine v2");
		await t.key("y");
		await t.waitFor(role("notice"), "Copied link to Sync engine v2");
		// A click on another card selects it and opens its page.
		await t.click(`${role("project-card")}:not([data-mark='selected'])`);
		await present(role("project-header"));
		const clicked = (await nodesOf(role("project-name")))[0]?.text ?? "";
		if (clicked.includes("Sync engine v2")) throw new Error("the click opened the previously selected project");
		await t.key("Escape");
		await absent(role("project-header"));
		await waitFor(async () => (await t.wait(150), (await nodesOf(selected)).length === 1 && (await t.text(selected)).includes(clicked)), {
			what: "the clicked card to stay selected",
			interval: 0,
		});

		await t.key("3");
		await see("Legacy importer");
		await search("legacy");
		await gone("Desktop app");
		await t.key("j");
		await t.waitFor(selected, "Legacy importer");
		await t.key("o");
		await t.waitFor(role("notice"), "Refusing to open a link outside linear.app.");
		await clearSearch("legacy".length);
		await t.key("1");
		await see("Desktop app");

		await t.key("v");
		await present(role("table"));
		await t.click(`${role("table")} .sf-tbl-row:not(.head)`);
		await t.key("v");
		await present(role("board"));
		await t.waitFor(selected, PROGRESS_DESC.split(",")[0]);
		await runner.shot(label);

		await t.key("Enter");
		await pageOpen(PROGRESS_DESC.split(",")[0]);
		await t.key("o");
		await waitFor(async () => (await t.wait(150), (await focusedLabel()).includes("linear.app")), {
			what: "a linear.app pane opened by o",
			interval: 0,
		});
	});

	await runner.step("readme-shots", async () => {
		// A fresh window on pristine data, signed in through the environment: no leftover notices or filters.
		operations = mock.log.map((entry) => entry.operationName);
		await t.stop();
		mock.reset();
		t = await startTern({
			env: { LINEAR_API_URL: mock.url, LINEAR_API_KEY: mock.apiKey },
			out: ternOut,
			size: "1440 900",
		});
		runner.attach(t);
		await t.openBlock();
		await see("Desktop app");
		await runner.shot("readme-projects-board");
		await t.key("v");
		await present(role("table"));
		await t.waitFor(role("table"), "Desktop app");
		await runner.shot("readme-projects-table");
		await t.key("v");
		await present(role("board"));
		for (let i = 0; i < 4; i += 1) await t.key("j");
		await t.waitFor(SELECTED_CARD, "Desktop app");
		await t.key("Enter");
		await pageOpen("Desktop app");
		await runner.shot("readme-project");
		await openActivity();
		await t.waitFor(role("activity"), "Beta is feature-complete");
		await runner.shot("readme-project-activity");
		await t.key("Escape");
		await absent(role("project-header"));

		await t.key("i");
		await see("Crash when opening large workspace");
		await runner.shot("readme-board");

		await t.key("v");
		await present(role("table"));
		await see("Crash when opening large workspace");
		await runner.shot("readme-table");
		await t.key("v");
		await present(role("board"));

		await t.key("n");
		await present(role("dialog"));
		await t.type("Add dark mode to the settings page");
		await t.waitFor(role("dialog"), "Add dark mode to the settings page");
		await runner.shot("readme-create");
		await t.key("Escape");
		await absent(role("dialog"));

		// ENG-142 has a description, a relation and a threaded conversation; the taller window shows all of them.
		await t.ctl("size 1440 1260");
		for (let i = 0; i < 4; i += 1) await t.key("j");
		await t.key("Enter");
		await present(role("drawer"));
		await t.waitFor(role("drawer"), "Crash when opening large workspace");
		await t.waitFor(role("comment"), "Fix is up for review");
		await runner.shot("readme-detail");
	});
}

let failure;
try {
	await scenario();
} catch (error) {
	failure = error;
}
runner.finish(failure === undefined, { mockOperations: operations.length > 0 ? operations : mock.log.map((entry) => entry.operationName) });
await t.stop();
mock.stop();
rmSync(ternOut, { recursive: true, force: true });

if (failure) {
	console.error(`\ne2e FAILED: ${failure instanceof Error ? failure.message : failure}`);
} else {
	console.log("\ne2e passed");
}
console.log(`artifacts: ${artifacts} (report.json, shots/)`);
process.exit(failure ? 1 : 0);
