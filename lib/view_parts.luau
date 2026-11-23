--!strict
-- Node builders and tone tables shared by the `main` views (view.luau: list; view_issues.luau: issue list;
-- view_project.luau: project page). Pure: builds nodes from values, never reads or mutates block state.

local model = require("./model")

local ui = tern.ui

local parts = {}

-- Linear's state colours cannot be inline, so a state type maps to the nearest tone.
parts.STATE_TONES = table.freeze({
	triage = "info",
	backlog = "muted",
	unstarted = "neutral",
	started = "warning",
	completed = "success",
	canceled = "muted",
	duplicate = "muted",
}) :: { [string]: string }

-- Project statuses map to tones by ProjectStatusType, like workflow states.
parts.PROJECT_STATUS_TONES = table.freeze({
	backlog = "muted",
	planned = "neutral",
	started = "warning",
	paused = "info",
	completed = "success",
	canceled = "muted",
}) :: { [string]: string }

parts.HEALTH_TONES = table.freeze({
	onTrack = "success",
	atRisk = "warning",
	offTrack = "error",
}) :: { [string]: string }

parts.PRIORITY_TONES = table.freeze({
	[1] = "error",
	[2] = "warning",
	[3] = "info",
	[4] = "muted",
}) :: { [number]: string }

-- Merges `props` into the node's props.
function parts.with(node: Node, props: { [string]: any }): Node
	local merged: { [string]: any } = node.p or {}
	for name, value in props do
		merged[name] = value
	end
	node.p = merged
	return node
end

-- The non-nil nodes among `nodes[1..count]`, in order.
function parts.compact(nodes: { Node? }, count: number): { Node }
	local out: { Node } = {}
	for index = 1, count do
		local node = nodes[index]
		if node ~= nil then
			table.insert(out, node)
		end
	end
	return out
end

-- The refresh button's label: "Refresh" before the first load, then "Synced 2m ago".
function parts.syncedLabel(fetchedAt: number?, now: number): string
	if fetchedAt == nil then
		return "Refresh"
	end
	local iso = os.date("!%Y-%m-%dT%H:%M:%SZ", fetchedAt) :: string
	local relative = model.relativeTime(iso, now)
	if relative == "now" then
		return "Synced just now"
	elseif string.match(relative, "^%d+[mhd]$") ~= nil then
		return `Synced {relative} ago`
	end
	return `Synced {relative}`
end

-- An error or notice line.
function parts.banner(key: string, role: string, tone: string, icon: string, message: string): Node
	return ui.node("row", { key = key, role = role, tone = tone, gap = "sm" }, {
		ui.node("icon", { key = "icon", name = icon, tone = tone }),
		ui.node("text", { key = "text", spans = { message }, grow = 1 }),
	})
end

-- A status dot: an empty text node drawn by CSS per `mark` (the state or project status type).
function parts.statusDot(tone: string, mark: string): Node
	return ui.node("text", {
		key = "dot",
		role = "linear.state-dot",
		tone = tone,
		mark = mark,
		spans = { "\u{00A0}" },
	})
end

-- The project health badge; nil before the first project update.
function parts.healthBadge(health: string?): Node?
	local tone = if health ~= nil then parts.HEALTH_TONES[health] else nil
	if health == nil or tone == nil then
		return nil
	end
	return parts.with(ui.badge(model.healthLabel(health), tone), {
		key = "health",
		role = "linear.project-health",
		mark = `health-{health}`,
	})
end

-- ─── Lists: view switch, layout toggle, filter row, board columns, sort bar, empty and loading states ──────────

local VIEWS: { { id: string, label: string } } = {
	{ id = "active", label = "Active" },
	{ id = "backlog", label = "Backlog" },
	{ id = "all", label = "All" },
}

local LAYOUTS: { { id: string, label: string, icon: string } } = {
	{ id = "board", label = "Board", icon = "kanban" },
	{ id = "table", label = "Table", icon = "list" },
}

local COLUMN_MIN_WIDTH = "30ch"
local MIN_COLUMN_LINES = 8

-- Active / Backlog / All (`view=<id>`), `current` on.
function parts.viewSwitcher(current: string): Node
	local buttons: { Node } = {}
	for _, entry in VIEWS do
		table.insert(
			buttons,
			ui.button(entry.label, {
				key = `view-{entry.id}`,
				role = `linear.view-{entry.id}`,
				on = current == entry.id,
				actions = { click = `view={entry.id}` },
			})
		)
	end
	return ui.node("buttons", { key = "views" }, buttons)
end

-- Board / Table (`layout=<id>`), the shared Prefs.layout on.
function parts.layoutSwitcher(layout: string): Node
	local buttons: { Node } = {}
	for _, entry in LAYOUTS do
		table.insert(
			buttons,
			ui.button(entry.label, {
				key = `layout-{entry.id}`,
				role = `linear.layout-{entry.id}`,
				icon = entry.icon,
				on = layout == entry.id,
				actions = { click = `layout={entry.id}` },
			})
		)
	end
	return ui.node("buttons", { key = "layouts" }, buttons)
end

-- The filter row: `selects` lead; **Clear filters** when `filtered`; the count (`count`, plus a warning when the list
-- was capped at `truncatedAt`) unless `counting` is false (the counts of a list being replaced would be wrong).
function parts.filterRow(
	selects: { Node },
	count: string,
	truncatedAt: number?,
	filtered: boolean,
	counting: boolean
): Node
	local summary: { Span | string } = { ui.span(count, "muted") }
	if truncatedAt ~= nil then
		table.insert(summary, ui.span(`  ·  Showing first {truncatedAt}`, "warning"))
	end
	local children = table.clone(selects)
	if filtered then
		table.insert(
			children,
			ui.button("Clear filters", {
				key = "clear-filters",
				role = "linear.clear-filters",
				variant = "quiet",
				icon = "funnel-x",
				actions = { click = "clear-filters" },
			})
		)
	end
	table.insert(children, ui.node("row", { key = "spacer", grow = 1 }))
	if counting then
		table.insert(children, ui.node("text", { key = "count", role = "linear.count", spans = summary }))
	end
	return ui.node("row", { key = "filters", role = "linear.filters", gap = "sm", wrap = true }, children)
end

-- One board column: a head (dot, title, count) over a scrolling stack of cards.
export type ColumnShell = {
	id: string,
	title: string,
	-- State or project status type: the column's and the dot's `mark`.
	kind: string,
	tone: string,
	cards: { Node },
	-- Shown when `cards` is empty.
	none: string,
}

function parts.columnNode(shell: ColumnShell, lines: number): Node
	local cards = shell.cards
	local count = #cards
	if count == 0 then
		cards =
			{ ui.node("text", { key = "none", role = "linear.column-empty", spans = { ui.span(shell.none, "dim") } }) }
	end
	local head = ui.node("row", { key = "head", role = "linear.column-head", gap = "sm" }, {
		parts.statusDot(shell.tone, shell.kind),
		ui.node("text", { key = "title", spans = { ui.span(shell.title, "strong") } }),
		ui.node("text", { key = "count", spans = { ui.span(tostring(count), "muted") } }),
	})
	return ui.node("col", {
		key = shell.id,
		role = "linear.column",
		mark = shell.kind,
		gap = "sm",
		grow = 1,
		basis = 0,
		min = { w = COLUMN_MIN_WIDTH },
	}, {
		head,
		ui.node("scroll", { key = "cards", gap = "sm", max = { h = `{lines}lines` } }, cards),
	})
end

-- Card space per column: the pane's rows minus `chromeRows` taken above the cards, at least MIN_COLUMN_LINES.
function parts.columnLines(cx: BlockCx, chromeRows: number): number
	return math.max(MIN_COLUMN_LINES, cx.rows - chromeRows)
end

function parts.boardRow(children: { Node }): Node
	return ui.node("row", { key = "content", role = "linear.board", gap = "md", align = "start" }, children)
end

-- `Sort` and one button per sortable column (`sort=<key>`); the active one shows its direction.
function parts.sortBar(entries: { { key: string, label: string } }, current: string, asc: boolean): Node
	local children: { Node } = { ui.node("text", { key = "label", spans = { ui.span("Sort", "muted") } }) }
	for _, entry in entries do
		local active = current == entry.key
		local arrow = if not active then "" elseif asc then " ↑" else " ↓"
		table.insert(
			children,
			ui.button(entry.label .. arrow, {
				key = `sort-{entry.key}`,
				role = `linear.sort-{entry.key}`,
				variant = "quiet",
				size = "sm",
				on = active,
				actions = { click = `sort={entry.key}` },
			})
		)
	end
	return ui.node("row", { key = "sort", role = "linear.sort", gap = "xs", wrap = true }, children)
end

-- Stands in for the board while a shown load replaces the list.
function parts.reloadingNode(label: string): Node
	return ui.node("row", { key = "content", role = "linear.reloading", gap = "sm" }, {
		ui.node("spinner", { key = "spinner", style = "braille" }),
		ui.node("text", { key = "label", spans = { ui.span(label, "muted") } }),
	})
end

function parts.clearFiltersEmptyButton(): Node
	return ui.button("Clear filters", {
		key = "empty-clear-filters",
		role = "linear.empty-clear-filters",
		icon = "funnel-x",
		actions = { click = "clear-filters" },
	})
end

-- **All** (`view=all`) on an empty view.
function parts.emptyAllButton(): Node
	return ui.button("All", { key = "empty-all", role = "linear.empty-all", actions = { click = "view=all" } })
end

function parts.emptyNode(filtered: boolean, noun: string): Node
	return ui.node("empty", {
		key = "content",
		role = "linear.empty",
		variant = "center",
		icon = if filtered then "funnel-x" else "inbox",
		title = if filtered then `No matching {noun}` else `No {noun} in this view`,
	})
end

function parts.withEmptyActions(nodes: { Node }, buttons: { Node }): { Node }
	if #buttons > 0 then
		table.insert(
			nodes,
			ui.node("row", { key = "empty-actions", role = "linear.empty-actions", gap = "sm" }, buttons)
		)
	end
	return nodes
end

return parts
