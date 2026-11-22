// Smoke test against the real Linear API (no mock).
//   bun test/live-smoke.mjs            read-only: projects board, table and a project page, then the issue board, table, detail drawer
//   bun test/live-smoke.mjs --write    also creates, comments on and completes one issue
//
// It also sends the read-only project queries once directly and prints Linear's `x-complexity` for each
// (Linear rejects a query above 10000).
//
// The key comes from LINEAR_API_KEY, else ~/.config/tern-linear-dev/api-key. It is never printed or written to the report.
// Screenshots and the report go to e2e-artifacts/live/.
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createRunner, repoRoot, startTern, waitFor } from "./harness.mjs";
import { extractQueries } from "./validate-queries.mjs";

const write = process.argv.includes("--write");
const artifacts = join(repoRoot, "e2e-artifacts/live");
const ternOut = join(artifacts, "tern-out");
const IDENTIFIER = /\b[A-Z][A-Z0-9]*-\d+\b/;

function readKey() {
	const fromEnv = process.env.LINEAR_API_KEY?.trim();
	if (fromEnv) return fromEnv;
	const file = join(homedir(), ".config/tern-linear-dev/api-key");
	if (existsSync(file)) return readFileSync(file, "utf8").trim();
	console.error("live-smoke: set LINEAR_API_KEY or create ~/.config/tern-linear-dev/api-key");
	process.exit(2);
}

const LINEAR_ENDPOINT = "https://api.linear.app/graphql";
const MAX_COMPLEXITY = 10_000;

/**
 * Sends each read-only project operation of lib/queries.luau once, with the variables the plugin uses, and returns
 * `{ operation, request, complexity, nodes }` per request. `Project` (the project page) asks for the first project of
 * the unfiltered list. Throws on a GraphQL error or a cost above the cap.
 */
async function measureComplexity(key) {
	const docs = Object.fromEntries(
		extractQueries(readFileSync(join(repoRoot, "lib/queries.luau"), "utf8")).map((q) => [q.key, q.text]),
	);
	const active = { and: [{ status: { type: { in: ["planned", "started", "paused"] } } }] };
	const requests = [
		["ProjectStatuses", {}, "organization statuses"],
		["Projects", { first: 50, filter: active }, "first 50, Active view"],
		["Projects", { first: 50 }, "first 50, All projects / All view (no filter)"],
		["ProjectsChanged", { filter: active }, "change check, Active view"],
	];
	const results = [];
	const send = async (operation, variables, request) => {
		const response = await fetch(LINEAR_ENDPOINT, {
			method: "POST",
			headers: { "content-type": "application/json", authorization: key.startsWith("lin_oauth_") ? `Bearer ${key}` : key },
			body: JSON.stringify({ query: docs[operation], operationName: operation, variables }),
		});
		const body = await response.json();
		if (body.errors?.length) throw new Error(`${operation}: ${body.errors[0].message}`);
		const complexity = Number(response.headers.get("x-complexity"));
		if (!(complexity <= MAX_COMPLEXITY)) throw new Error(`${operation}: complexity ${complexity} over ${MAX_COMPLEXITY}`);
		const nodes =
			body.data.projects?.nodes?.length ??
			body.data.organization?.projectStatuses?.length ??
			body.data.project?.projectMilestones?.nodes?.length;
		results.push({ operation, request, complexity, nodes });
		return body.data;
	};
	let firstProject;
	for (const [operation, variables, request] of requests) {
		const data = await send(operation, variables, request);
		if (operation === "Projects" && !variables.filter) firstProject = data.projects.nodes[0]?.id;
	}
	if (firstProject) await send("Project", { id: firstProject }, "project page detail (nodes: milestones)");
	return results;
}

rmSync(artifacts, { recursive: true, force: true });
mkdirSync(artifacts, { recursive: true });

const apiKey = readKey();
// Never point the plugin at the mock: LINEAR_API_URL is stripped from the child environment by the harness.
const t = await startTern({ env: { LINEAR_API_KEY: apiKey }, out: ternOut, size: "1440 900" });
const runner = createRunner(t, { dir: artifacts, title: write ? "tern-linear live smoke (write)" : "tern-linear live smoke" });

const role = (name) => `[data-role='linear.${name}']`;
const exists = async (selector) => ((await t.tree(selector)).nodes ?? []).length > 0;
// Polling advances app time (`wait 150`): headless Tern only animates and renders as time passes.
const present = (selector, timeout) =>
	waitFor(async () => (await t.wait(150), exists(selector)), { what: `${selector} to appear`, timeout, interval: 0 });
const absent = (selector) =>
	waitFor(async () => (await t.wait(150), !(await exists(selector))), { what: `${selector} to disappear`, interval: 0 });
const backspaces = async (count) => {
	for (let i = 0; i < count; i += 1) await t.key("Backspace");
};

async function closeDrawer() {
	for (let attempt = 0; attempt < 4 && (await exists(role("drawer"))); attempt += 1) await t.key("Escape");
	await absent(role("drawer"));
}

/** Number of cards once it has not changed for `quietMs` (and, while it is 0, for at least `emptyMs`). */
async function cardCountSettled({ quietMs = 2500, emptyMs = 6000, timeout = 45_000 } = {}) {
	const began = Date.now();
	let count = -1;
	let since = began;
	for (;;) {
		await t.wait(150);
		const now = Date.now();
		const current = ((await t.tree(role("card"))).nodes ?? []).length;
		if (current !== count) {
			count = current;
			since = now;
		}
		if (now - since >= quietMs && (count > 0 || now - began >= emptyMs)) return count;
		if (now - began > timeout) throw new Error("the board never settled");
	}
}

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

let created;
let hasIssues = false;
const report = runner.report;

async function scenario() {
	await runner.step("projects-load", async (label) => {
		await t.openBlock();
		// Loaded = the loading screen is gone and something else (board, empty state, setup or error) shows.
		await waitFor(
			async () => {
				await t.wait(150);
				if (await exists(role("loading"))) return false;
				return (await exists(role("board"))) || (await exists(role("empty"))) || (await exists(role("setup"))) || (await exists(role("error")));
			},
			{ what: "the board to load", timeout: 45_000, interval: 0 },
		);
		if (await exists(role("setup"))) throw new Error("the plugin shows the setup screen; the API key was not picked up");
		if (await exists(role("error"))) throw new Error(`error banner: ${(await t.text(role("error"))).slice(0, 300)}`);
		if (!(await exists(`${role("mode-projects")}`))) throw new Error("no mode switch in the top bar");
		const count = (await t.tree(role("project-card"))).nodes?.length ?? 0;
		const columns = ((await t.tree(role("column-head"))).nodes ?? []).map((node) => (node.text ?? "").replace(/\d+$/, ""));
		console.log(`note: projects board (All projects, Active): ${count} cards in ${columns.length} columns: ${columns.join(", ")}`);
		report.projects = { cards: count, columns };
		await runner.shot(label);
	});

	await runner.step("projects-table", async (label) => {
		await t.key("3");
		await waitFor(async () => (await t.wait(150), !(await exists(role("reloading")))), { what: "the All view", timeout: 45_000, interval: 0 });
		if (!(await exists(role("project-card")))) {
			console.log("note: the workspace has no projects; the projects table is skipped");
			await t.key("1");
			return;
		}
		await t.key("v");
		await present(role("table"));
		await runner.shot(label);
		await t.key("v");
		await present(role("board"));
		await t.key("1");
	});

	// Read-only: opens the first project of the Active view (else of the All view) on its page, then goes back.
	await runner.step("project-page", async (label) => {
		await waitFor(async () => (await t.wait(150), !(await exists(role("reloading")))), { what: "the Active view", timeout: 45_000, interval: 0 });
		let allView = false;
		if (!(await exists(role("project-card")))) {
			allView = true;
			await t.key("3");
			await waitFor(async () => (await t.wait(150), !(await exists(role("reloading")))), { what: "the All view", timeout: 45_000, interval: 0 });
		}
		if (!(await exists(role("project-card")))) {
			console.log("note: the workspace has no projects; the project page is skipped");
			await t.key("1");
			return;
		}
		await t.key("j");
		await t.key("Enter");
		await present(role("project-header"));
		await waitFor(
			async () => {
				await t.wait(150);
				if (await exists(role("project-error"))) throw new Error(`project page error: ${(await t.text(role("project-error"))).slice(0, 300)}`);
				return (await exists(role("project-description"))) || (await exists(role("project-description-empty")));
			},
			{ what: "the project detail", timeout: 45_000, interval: 0 },
		);
		if (await exists(role("error"))) throw new Error(`error banner: ${(await t.text(role("error"))).slice(0, 300)}`);
		const milestones = ((await t.tree(role("milestone"))).nodes ?? []).length;
		const described = await exists(role("project-description"));
		console.log(`note: project page: ${described ? "with" : "without"} a description, ${milestones} milestones`);
		report.projectPage = { described, milestones };
		await runner.shot(label);
		await t.key("Escape");
		await absent(role("project-header"));
		await present(role("board"));
		if (allView) await t.key("1");
	});

	await runner.step("project-query-complexity", async () => {
		report.complexity = await measureComplexity(apiKey);
		for (const { operation, request, complexity, nodes } of report.complexity) {
			console.log(`complexity: ${operation} (${request}): ${complexity} of ${MAX_COMPLEXITY}, ${nodes} nodes`);
		}
	});

	await runner.step("issues-mode", async (label) => {
		await t.key("i");
		await waitFor(
			async () => {
				await t.wait(150);
				if (await exists(role("reloading"))) return false;
				return (await exists(role("board"))) || (await exists(role("empty"))) || (await exists(role("error")));
			},
			{ what: "the issue board to load", timeout: 45_000, interval: 0 },
		);
		if (await exists(role("error"))) throw new Error(`error banner: ${(await t.text(role("error"))).slice(0, 300)}`);
		await t.waitFor(role("search"), "Search issues");
		await runner.shot(label);
	});

	// "My issues / Active" can be legitimately empty, so look at everything in the first team. Switching scope
	// reloads from the network and the empty state shows meanwhile, so wait until the card count stops changing.
	await runner.step("team-scope-all-view", async (label) => {
		await t.key("t");
		await cardCountSettled();
		await t.key("3");
		const count = await cardCountSettled();
		hasIssues = count > 0;
		if (hasIssues) {
			const cards = await t.text(role("card"));
			if (!IDENTIFIER.test(cards)) throw new Error(`cards show no issue identifier: ${cards.slice(0, 200)}`);
			console.log(`note: ${count} cards in the first team's All view`);
		} else {
			console.log("note: the workspace has no issues in the first team's All view; table and drawer steps are skipped");
			report.skipped = "no issues in the first team";
		}
		await runner.shot(label);
	});

	if (hasIssues) {
		await runner.step("table-view", async (label) => {
			await t.key("v");
			await present(role("table"));
			await waitFor(async () => (await t.wait(150), IDENTIFIER.test(await t.text(role("table")))), {
				what: "issue identifiers in the table",
				interval: 0,
			});
			await runner.shot(label);
			await t.key("v");
			await present(role("board"));
		});

		await runner.step("detail-drawer", async (label) => {
			await t.click(role("card"));
			await present(role("drawer"));
			await t.waitFor(role("drawer"), "Comments");
			await runner.shot(label);
			await closeDrawer();
		});
	}

	if (!write) return;

	await runner.step("create-issue", async (label) => {
		const title = `[tern-linear smoke] ${new Date().toISOString()}`;
		created = { title };
		await t.key("n");
		await present(role("dialog"));
		await t.type(title);
		await t.key("Ctrl+Enter");
		await absent(role("dialog"));
		await t.waitFor(role("notice"), "Created", { timeout: 30_000 });
		const notice = await t.text(role("notice"));
		created.identifier = IDENTIFIER.exec(notice)?.[0] ?? "(identifier not shown)";
		await runner.shot(label);
	});

	await runner.step("comment-and-complete", async (label) => {
		const { title } = created;
		const needle = title.slice("[tern-linear smoke] ".length);
		await search(needle);
		await t.waitFor(role("card"), needle, { timeout: 30_000 });
		await t.click(role("card"));
		await present(role("drawer"));
		await t.key("c");
		await t.type("Posted by the tern-linear live smoke test.");
		await t.key("Ctrl+Enter");
		await t.waitFor(role("drawer"), "Posted by the tern-linear live smoke test.");
		await t.key("x");
		await present(role("reopen"));
		await runner.shot(label);
		await closeDrawer();
		await clearSearch(needle.length);
	});
}

let failure;
try {
	await scenario();
} catch (error) {
	failure = error;
}
runner.finish(failure === undefined, created ? { createdIssue: created.identifier ?? created.title } : {});
await t.stop();
rmSync(ternOut, { recursive: true, force: true });

if (failure) {
	console.error(`\nlive smoke FAILED: ${failure instanceof Error ? failure.message : failure}`);
} else {
	console.log("\nlive smoke passed");
	if (created) console.log(`created and completed: ${created.identifier} (${created.title})`);
}
console.log(`artifacts: ${artifacts}`);
process.exit(failure ? 1 : 0);
