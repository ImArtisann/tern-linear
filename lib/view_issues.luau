--!strict
-- The issue list: filter row (priority, assignee, label), board, table with its sort bar, empty and loading states.
-- One renderer for issues mode (view.luau) and the project page's Issues tab (view_project.luau); each describes its
-- list as an IssueList. Pure: reads the block state, never mutates it.

local model = require("./model")
local parts = require("./view_parts")
local types = require("./types")

type BlockState = types.BlockState
type Issue = types.Issue
type Label = types.Label
type Team = types.Team
type User = types.User
type Column = model.Column

local ui = tern.ui
local with = parts.with
local compact = parts.compact

local issueList = {}

-- What one issue list shows. Issues mode builds it from BlockState and Prefs, the Issues tab from ProjectIssuesState.
export type IssueList = {
	-- The loaded issues, before the client filters.
	items: { Issue },
	-- The server capped the list (the count warns `Showing first N`).
	truncated: boolean,
	-- The server filter's view: the state types the board's columns show.
	view: string,
	filters: types.IssueFilters,
	query: string,
	-- Table sort key and direction.
	sort: string,
	sortAsc: boolean,
	selectedId: string?,
	-- Team scope: one column per workflow state of this team; nil: one column per state type.
	team: Team?,
	-- The assignee select's members (besides Me and Unassigned) and the label select's labels.
	members: { User },
	labels: { Label },
	-- A shown load replaces the list: a loading row stands in for the board and the count is hidden.
	reloading: boolean,
	-- The empty, unfiltered list: "mine" (My issues) adds the hint with All and Choose team on the Active view;
	-- "all" offers All outside the All view; "none" adds nothing.
	emptyHelp: "mine" | "all" | "none",
	-- Cards and the table show each issue's project milestone (the Issues tab while no milestone filter is set).
	milestones: boolean,
	-- Pane rows taken above the cards (bars, banners, column heads).
	chromeRows: number,
}

local PRIORITY_TONES = parts.PRIORITY_TONES
local STATE_TONES = parts.STATE_TONES

local SORT_COLUMNS: { { key: string, label: string } } = {
	{ key = "identifier", label = "ID" },
	{ key = "title", label = "Title" },
	{ key = "state", label = "State" },
	{ key = "priority", label = "Priority" },
	{ key = "assignee", label = "Assignee" },
	{ key = "updated", label = "Updated" },
}

local MAX_CARD_LABELS = 3

local function viewerIdOf(state: BlockState): string?
	return if state.viewer ~= nil then state.viewer.user.id else nil
end

local function pluralIssues(count: number): string
	return if count == 1 then "1 issue" else `{count} issues`
end

local function filtered(list: IssueList): boolean
	local filters = list.filters
	return filters.priority ~= nil
		or filters.assignee ~= nil
		or filters.labelId ~= nil
		or string.match(list.query, "%S") ~= nil
end

-- The list after the client filters, in board order.
function issueList.visible(state: BlockState, list: IssueList): { Issue }
	return model.visible(list.items, list.filters, list.query, viewerIdOf(state))
end

-- ─── Filter row ─────────────────────────────────────────────────────────────

local function prioritySelect(list: IssueList): Node
	local options: { { value: string, label: string } } = { { value = "", label = "Any priority" } }
	for _, entry in model.PRIORITIES do
		table.insert(options, { value = tostring(entry.value), label = entry.label })
	end
	local priority = list.filters.priority
	return ui.node("select", {
		key = "filter-priority",
		role = "linear.filter-priority",
		value = if priority ~= nil then tostring(priority) else "",
		options = options,
		variant = "quiet",
		aria = "Priority filter",
	})
end

local function assigneeSelect(state: BlockState, list: IssueList): Node
	local options: { { value: string, label: string } } = {
		{ value = "", label = "Any assignee" },
		{ value = "me", label = "Me" },
		{ value = "none", label = "Unassigned" },
	}
	local viewerId = viewerIdOf(state)
	for _, member in list.members do
		if member.id ~= viewerId then
			table.insert(options, { value = member.id, label = member.displayName })
		end
	end
	return ui.node("select", {
		key = "filter-assignee",
		role = "linear.filter-assignee",
		value = list.filters.assignee or "",
		options = options,
		variant = "quiet",
		aria = "Assignee filter",
	})
end

local function labelSelect(list: IssueList): Node
	local options: { { value: string, label: string } } = { { value = "", label = "Any label" } }
	for _, label in list.labels do
		table.insert(options, { value = label.id, label = label.name })
	end
	return ui.node("select", {
		key = "filter-label",
		role = "linear.filter-label",
		value = list.filters.labelId or "",
		options = options,
		variant = "quiet",
		aria = "Label filter",
	})
end

-- Priority, assignee and label selects, Clear filters, and the visible count.
function issueList.filterRow(state: BlockState, list: IssueList, visibleCount: number): Node
	local selects = { prioritySelect(list), assigneeSelect(state, list), labelSelect(list) }
	local truncatedAt = if list.truncated then #list.items else nil
	return parts.filterRow(selects, pluralIssues(visibleCount), truncatedAt, filtered(list), not list.reloading)
end

-- ─── Board ──────────────────────────────────────────────────────────────────

local function labelChips(issue: Issue): { Node }
	local chips: { Node } = {}
	for index, label in issue.labels do
		if index > MAX_CARD_LABELS then
			local more = ui.badge(`+{#issue.labels - MAX_CARD_LABELS}`, "muted")
			table.insert(chips, with(more, { key = "more", mark = "label" }))
			break
		end
		table.insert(chips, with(ui.badge(label.name, "neutral"), { key = `label-{label.id}`, mark = "label" }))
	end
	return chips
end

local function cardHead(issue: Issue): Node
	local priorityTone = PRIORITY_TONES[issue.priority]
	local blocked = model.isBlocked(issue)
	local children = compact({
		ui.node("text", { key = "id", spans = { ui.span(issue.identifier, "mono muted") } }),
		ui.node("row", { key = "spacer", grow = 1 }),
		if blocked then with(ui.badge("Blocked", "error"), { key = "blocked", mark = "blocked" }) else nil,
		if priorityTone ~= nil
			then with(ui.badge(model.priorityLabel(issue.priority), priorityTone), {
				key = "priority",
				mark = `priority-{issue.priority}`,
			})
			else nil,
	}, 4)
	return ui.node("row", { key = "head", gap = "xs" }, children)
end

local function cardFoot(issue: Issue, milestones: boolean): Node?
	local chips = labelChips(issue)
	local assignee = issue.assignee
	local milestone = if milestones then issue.projectMilestone else nil
	if #chips == 0 and assignee == nil and milestone == nil then
		return nil
	end
	local children: { Node } = {}
	if milestone ~= nil then
		table.insert(
			children,
			ui.node("text", {
				key = "milestone",
				role = "linear.card-milestone",
				title = `Milestone: {milestone.name}`,
				spans = { ui.span(`◆ {milestone.name}`, "muted") },
				max = { w = "18ch" },
			})
		)
	end
	table.insert(children, ui.node("row", { key = "labels", gap = "xs", wrap = true, grow = 1 }, chips))
	if assignee ~= nil then
		table.insert(
			children,
			ui.node("text", {
				key = "assignee",
				role = "linear.card-assignee",
				title = assignee.name,
				spans = { ui.span(assignee.displayName, "muted") },
				max = { w = "14ch" },
			})
		)
	end
	return ui.node("row", { key = "foot", gap = "sm", align = "start" }, children)
end

local function issueCard(issue: Issue, selectedId: string?, milestones: boolean): Node
	local children = compact({
		cardHead(issue),
		ui.node("text", { key = "title", role = "linear.card-title", max = { h = "2lines" }, spans = { issue.title } }),
		cardFoot(issue, milestones),
	}, 3)
	return ui.node("col", {
		key = issue.id,
		role = "linear.card",
		gap = "xs",
		mark = if issue.id == selectedId then "selected" else nil,
		actions = { click = `select={issue.id}` },
	}, children)
end

local function boardColumn(column: Column, list: IssueList, lines: number): Node
	local cards: { Node } = {}
	for _, issue in column.issues do
		table.insert(cards, issueCard(issue, list.selectedId, list.milestones))
	end
	return parts.columnNode({
		id = column.id,
		title = column.title,
		kind = column.stateType,
		tone = STATE_TONES[column.stateType] or "muted",
		cards = cards,
		none = "No issues",
	}, lines)
end

-- The board's columns: the team's workflow states, or one per state type.
function issueList.columns(list: IssueList, visible: { Issue }): { Column }
	local team = list.team
	if team ~= nil then
		return model.teamColumns(visible, team, list.view)
	end
	return model.typeColumns(visible, list.view)
end

local function board(cx: BlockCx, list: IssueList, visible: { Issue }): Node
	local lines = parts.columnLines(cx, list.chromeRows)
	local children: { Node } = {}
	for _, column in issueList.columns(list, visible) do
		table.insert(children, boardColumn(column, list, lines))
	end
	return parts.boardRow(children)
end

-- ─── Table ──────────────────────────────────────────────────────────────────

local TABLE_COLUMNS: { Col } = {
	{ id = "id", head = "ID", mono = true, priority = 8 },
	{ id = "title", head = "Title", grow = 1, priority = 9 },
	{ id = "state", head = "State", priority = 6 },
	{ id = "priority", head = "Priority", priority = 5 },
	{ id = "assignee", head = "Assignee", priority = 3 },
	{ id = "updated", head = "Updated", align = "end", priority = 2 },
}

-- The same columns with the project milestone before the last one (Updated); it is the first to go on a narrow pane.
local MILESTONE_TABLE_COLUMNS: { Col } = table.clone(TABLE_COLUMNS)
table.insert(MILESTONE_TABLE_COLUMNS, #TABLE_COLUMNS, { id = "milestone", head = "Milestone", priority = 1 })

local function priorityCell(issue: Issue): Cell
	local tone = PRIORITY_TONES[issue.priority]
	if tone == nil then
		return ""
	end
	return { badge = { text = model.priorityLabel(issue.priority), tone = tone } }
end

local function tableRow(issue: Issue, now: number, milestones: boolean): TableRow
	local assignee = issue.assignee
	local cells: { Cell } = {
		issue.identifier,
		issue.title,
		{ text = issue.state.name, dot = STATE_TONES[issue.state.type] or "muted" },
		priorityCell(issue),
		if assignee ~= nil then assignee.displayName else "",
	}
	if milestones then
		local milestone = issue.projectMilestone
		table.insert(cells, if milestone ~= nil then milestone.name else "")
	end
	table.insert(cells, model.relativeTime(issue.updatedAt, now))
	return { id = issue.id, cells = cells }
end

local function issueTable(list: IssueList, visible: { Issue }, now: number): Node
	local rows: { TableRow } = {}
	for _, issue in model.sortTable(visible, list.sort, list.sortAsc) do
		table.insert(rows, tableRow(issue, now, list.milestones))
	end
	local columns = if list.milestones then MILESTONE_TABLE_COLUMNS else TABLE_COLUMNS
	local node = ui.table(columns, rows, { selectable = true, selected = list.selectedId })
	return with(node, { key = "table", role = "linear.table" })
end

-- ─── Content ────────────────────────────────────────────────────────────────

local function emptyState(state: BlockState, list: IssueList): { Node }
	local isFiltered = filtered(list)
	local nodes: { Node } = { parts.emptyNode(isFiltered, "issues") }
	local buttons: { Node } = {}
	if isFiltered then
		table.insert(buttons, parts.clearFiltersEmptyButton())
	elseif list.emptyHelp == "mine" and list.view == "active" then
		table.insert(
			nodes,
			ui.node("text", {
				key = "empty-hint",
				role = "linear.empty-hint",
				spans = { ui.span("Nothing assigned to you is active.", "muted") },
			})
		)
		table.insert(buttons, parts.emptyAllButton())
		if #state.teams > 0 then
			table.insert(
				buttons,
				ui.button("Choose team", {
					key = "empty-team",
					role = "linear.empty-team",
					actions = { click = "focus-team" },
				})
			)
		end
	elseif list.emptyHelp == "all" and list.view ~= "all" then
		table.insert(buttons, parts.emptyAllButton())
	end
	return parts.withEmptyActions(nodes, buttons)
end

-- The loading row, the empty state, the sort bar and table, or the board.
function issueList.content(state: BlockState, cx: BlockCx, list: IssueList, visible: { Issue }, now: number): { Node }
	if list.reloading then
		return { parts.reloadingNode("Loading issues…") }
	end
	if #visible == 0 then
		return emptyState(state, list)
	end
	if state.prefs.layout == "table" then
		return { parts.sortBar(SORT_COLUMNS, list.sort, list.sortAsc), issueTable(list, visible, now) }
	end
	return { board(cx, list, visible) }
end

return issueList
