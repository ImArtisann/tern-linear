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

	// From here on the original issue scenario runs in issues mode.
	await runner.step("mode-issues", async (label) => {
		const before = mark();
		await t.key("i");
		await see("Crash when opening large workspace");
		const issues = opsSince(before, "Issues");
		if (issues.length === 0) throw new Error("no Issues request after switching to Issues");
		if (!JSON.stringify(issues[0].variables.filter).includes("isMe")) {
			throw new Error(`first board load is not scoped to my issues: ${JSON.stringify(issues[0].variables.filter)}`);
		}
		await t.waitFor(role("search"), "Search issues");
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

	// Last in this Tern: a successful `o` opens a web pane that takes the focus.
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
		await t.key("Enter");
		await t.wait(300);
		if (await exists(role("drawer"))) throw new Error("Enter opened a drawer in projects mode");
		await t.key("y");
		await t.waitFor(role("notice"), "Copied link to Sync engine v2");
		await t.click(`${role("project-card")}:not([data-mark='selected'])`);
		await waitFor(async () => (await t.wait(150), (await nodesOf(selected)).length === 1 && !(await t.text(selected)).includes("Sync engine v2")), {
			what: "a click to select another card",
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
