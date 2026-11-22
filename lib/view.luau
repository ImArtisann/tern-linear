--!strict
-- The `main` region: setup screen, top bar, filters, board, table, empty and error states.
-- Pure: nothing here mutates state. The drawer and dialogs come from view_detail as the `layer`; the issue list
-- (filter row, board, table) comes from view_issues, shared with the project page's Issues tab.

local detail = require("./view_detail")
local issueList = require("./view_issues")
local model = require("./model")
local parts = require("./view_parts")
local projectPage = require("./view_project")
local types = require("./types")

type BlockState = types.BlockState
type Project = types.Project
type Team = types.Team
type ProjectColumn = model.ProjectColumn

local ui = tern.ui

local view = {}

-- ─── Node ids ───────────────────────────────────────────────────────────────
-- A node id is `<parent id>.<key>` from the region root. Fields keep these keys on every render.

local KEY_SETUP = "setup"
local KEY_SETUP_KEY = "key"
local KEY_BAR = "bar"
local KEY_SEARCH = "search"

local SETUP_FIELD_ID = `main.{KEY_SETUP}.{KEY_SETUP_KEY}`
local SEARCH_FIELD_ID = `main.{KEY_BAR}.{KEY_SEARCH}`

local KEY_URL = "https://linear.app/settings/account/security"

-- ─── Look-up tables ─────────────────────────────────────────────────────────

local PROJECT_STATUS_TONES = parts.PROJECT_STATUS_TONES
local HEALTH_TONES = parts.HEALTH_TONES

local PROJECT_SORT_COLUMNS: { { key: string, label: string } } = {
	{ key = "name", label = "Name" },
	{ key = "status", label = "Status" },
	{ key = "health", label = "Health" },
	{ key = "lead", label = "Lead" },
	{ key = "target", label = "Target" },
	{ key = "progress", label = "Progress" },
	{ key = "updated", label = "Updated" },
}

local MODES: { { id: string, label: string } } = {
	{ id = "projects", label = "Projects" },
	{ id = "issues", label = "Issues" },
}

-- Pane rows taken by the bar, filter row and column headers; the rest is card space (a row is one
-- 18px line). The bar wraps onto a second line below BAR_WRAP_COLS, and each banner takes three rows.
local BOARD_CHROME_ROWS = 12
local BAR_WRAP_COLS = 140
local BAR_WRAP_ROWS = 3
local BANNER_ROWS = 3

-- ─── Helpers ────────────────────────────────────────────────────────────────

local with = parts.with
local compact = parts.compact
local banner = parts.banner
local healthBadge = parts.healthBadge
local syncedLabel = parts.syncedLabel

local function selectedTeam(state: BlockState): Team?
	if state.prefs.scope ~= "team" then
		return nil
	end
	for _, team in state.teams do
		if team.id == state.prefs.teamId then
			return team
		end
	end
	return nil
end

local function inProjects(state: BlockState): boolean
	return state.prefs.mode == "projects"
end

-- The search text of the active mode.
local function activeQuery(state: BlockState): types.Field
	return if inProjects(state) then state.projects.query else state.query
end

-- Projects mode's client filters or search are set.
local function projectFiltersActive(state: BlockState): boolean
	local prefs = state.prefs
	local query = string.match(state.projects.query.text, "%S") ~= nil
	return prefs.projectLead ~= nil or prefs.projectHealth ~= nil or query
end

local function viewerIdOf(state: BlockState): string?
	return if state.viewer ~= nil then state.viewer.user.id else nil
end

local function pluralProjects(count: number): string
	return if count == 1 then "1 project" else `{count} projects`
end

-- ─── Setup and loading ──────────────────────────────────────────────────────

local function setupCard(state: BlockState): Node
	local failure = state.setupError
	local createSpans: { Span | string } = {
		"Create a personal API key at ",
		ui.link(KEY_URL, KEY_URL),
		". It needs Read, Create/update issues and Create comments permissions, or Full access.",
	}
	local children = compact({
		ui.node("text", {
			key = "head",
			spans = { ui.span("Connect Linear", "strong") },
			mark = "heading",
		}),
		ui.node("text", { key = "create", spans = createSpans }),
		ui.node("text", {
			key = "storage",
			spans = {
				ui.span(
					"The key is saved in the plugin data folder in a file created owner-only (umask 077). "
						.. "LINEAR_API_KEY in Tern's environment works too.",
					"muted"
				),
			},
		}),
		ui.node("input", {
			key = KEY_SETUP_KEY,
			role = "linear.setup-key",
			text = state.setupKey.text,
			cursor = state.setupKey.cursor,
			anchor = state.setupKey.anchor,
			placeholder = "lin_api_…",
			secret = true,
			mono = true,
			variant = "field",
		}),
		if failure ~= nil
			then ui.node("text", {
				key = "error",
				role = "linear.setup-error",
				tone = "error",
				spans = { ui.span(failure, "error") },
			})
			else nil,
		ui.button("Connect", {
			key = "save",
			role = "linear.setup-save",
			variant = "primary",
			keys = { "enter" },
			busy = state.busy,
			actions = { click = "save-key" },
		}),
	}, 6)
	return ui.node("col", { key = KEY_SETUP, role = "linear.setup", gap = "md", max = { w = "60ch" } }, children)
end

local function loadingNode(): Node
	return ui.node("spinner", {
		key = "loading",
		role = "linear.loading",
		style = "braille",
		label = "Loading Linear…",
	})
end

-- Stands in for the board while a foreground load runs over an already-ready screen.
local function reloadingNode(state: BlockState): Node
	return parts.reloadingNode(if inProjects(state) then "Loading projects…" else "Loading issues…")
end

-- ─── Top bar ────────────────────────────────────────────────────────────────

local function modeSwitcher(state: BlockState): Node
	local buttons: { Node } = {}
	for _, entry in MODES do
		table.insert(
			buttons,
			ui.button(entry.label, {
				key = `mode-{entry.id}`,
				role = `linear.mode-{entry.id}`,
				on = state.prefs.mode == entry.id,
				actions = { click = `mode={entry.id}` },
			})
		)
	end
	return ui.node("buttons", { key = "modes" }, buttons)
end

local function issueScopeSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = { { value = "mine", label = "My issues" } }
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = `{team.key} · {team.name}` })
	end
	local prefs = state.prefs
	local value = if prefs.scope == "team" and prefs.teamId ~= nil then prefs.teamId else "mine"
	return ui.node("select", {
		key = detail.controlKey("team-select", state.controlEpoch),
		role = "linear.team-select",
		value = value,
		options = options,
		variant = "field",
		disabled = if state.busy then true else nil,
		aria = "Scope",
	})
end

-- Same place and role as the issue scope select; its own key so switching modes remounts it.
local function projectScopeSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = {
		{ value = "all", label = "All projects" },
		{ value = "mine", label = "My projects" },
	}
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = `{team.key} · {team.name}` })
	end
	local prefs = state.prefs
	local value = if prefs.projectScope == "team" and prefs.projectTeamId ~= nil
		then prefs.projectTeamId
		else prefs.projectScope
	return ui.node("select", {
		key = detail.controlKey("project-scope-select", state.controlEpoch),
		role = "linear.team-select",
		value = value,
		options = options,
		variant = "field",
		disabled = if state.busy then true else nil,
		aria = "Project scope",
	})
end

local function searchField(state: BlockState): Node
	local query = activeQuery(state)
	return ui.node("input", {
		key = KEY_SEARCH,
		role = "linear.search",
		text = query.text,
		cursor = query.cursor,
		anchor = query.anchor,
		placeholder = if inProjects(state) then "Search projects" else "Search issues",
		icon = "search",
		keys = { "/" },
		variant = "field",
		grow = 1,
		min = { w = "16ch" },
		max = { w = "40ch" },
	})
end

local function refreshButton(state: BlockState, now: number): Node
	local fetchedAt = if inProjects(state) then state.projects.fetchedAt else state.fetchedAt
	return ui.button(syncedLabel(fetchedAt, now), {
		key = "refresh",
		role = "linear.refresh",
		icon = "repeat",
		keys = { "r" },
		busy = state.refreshing or state.busy,
		actions = { click = "refresh" },
	})
end

local function barActions(state: BlockState, now: number): Node
	local children = compact({
		refreshButton(state, now),
		if inProjects(state)
			then nil
			else ui.button("New issue", {
				key = "new",
				role = "linear.new",
				variant = "primary",
				icon = "plus",
				keys = { "n" },
				actions = { click = "create" },
			}),
		if state.keySource == "file"
			then ui.button("Sign out", {
				key = "sign-out",
				role = "linear.sign-out",
				variant = "quiet",
				actions = { click = "sign-out" },
			})
			else nil,
	}, 3)
	return ui.node("row", { key = "actions", role = "linear.bar-actions", gap = "sm" }, children)
end

local function topBar(state: BlockState, now: number): Node
	local children = compact({
		modeSwitcher(state),
		if inProjects(state) then projectScopeSelect(state) else issueScopeSelect(state),
		parts.viewSwitcher(if inProjects(state) then state.prefs.projectView else state.prefs.view),
		searchField(state),
		parts.layoutSwitcher(state.prefs.layout),
		barActions(state, now),
	}, 6)
	return ui.node("row", { key = KEY_BAR, role = "linear.bar", gap = "sm", wrap = true }, children)
end

-- ─── Filter row ─────────────────────────────────────────────────────────────

-- Team scope lists the team's labels; "my issues" has no single team, so it lists the labels in use.
local function availableLabels(state: BlockState, team: Team?): { types.Label }
	if team ~= nil then
		return team.labels
	end
	local seen: { [string]: boolean } = {}
	local labels: { types.Label } = {}
	for _, issue in state.issues do
		for _, label in issue.labels do
			if not seen[label.id] then
				seen[label.id] = true
				table.insert(labels, label)
			end
		end
	end
	table.sort(labels, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return labels
end

-- Leads of the loaded projects (the viewer has "Me"), by name.
local function projectLeads(state: BlockState): { types.User }
	local viewerId = viewerIdOf(state)
	local seen: { [string]: boolean } = {}
	local leads: { types.User } = {}
	for _, project in state.projects.items do
		local lead = project.lead
		if lead ~= nil and lead.id ~= viewerId and not seen[lead.id] then
			seen[lead.id] = true
			table.insert(leads, lead)
		end
	end
	table.sort(leads, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return leads
end

local function leadSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = {
		{ value = "", label = "Any lead" },
		{ value = "me", label = "Me" },
		{ value = "none", label = "No lead" },
	}
	for _, lead in projectLeads(state) do
		table.insert(options, { value = lead.id, label = lead.displayName })
	end
	return ui.node("select", {
		key = "filter-lead",
		role = "linear.filter-lead",
		value = state.prefs.projectLead or "",
		options = options,
		variant = "quiet",
		aria = "Lead filter",
	})
end

local function healthSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = { { value = "", label = "Any health" } }
	for _, entry in model.HEALTHS do
		table.insert(options, { value = entry.value, label = entry.label })
	end
	table.insert(options, { value = "none", label = "No update" })
	return ui.node("select", {
		key = "filter-health",
		role = "linear.filter-health",
		value = state.prefs.projectHealth or "",
		options = options,
		variant = "quiet",
		aria = "Health filter",
	})
end

local function projectFilterRow(state: BlockState, visibleCount: number): Node
	local projects = state.projects
	local truncatedAt = if projects.truncated then #projects.items else nil
	return parts.filterRow(
		{ leadSelect(state), healthSelect(state) },
		pluralProjects(visibleCount),
		truncatedAt,
		projectFiltersActive(state),
		not state.reloading
	)
end

-- ─── Board ──────────────────────────────────────────────────────────────────

local function chromeRows(state: BlockState, cx: BlockCx): number
	local rows = BOARD_CHROME_ROWS
	if cx.cols < BAR_WRAP_COLS then
		rows += BAR_WRAP_ROWS
	end
	if state.error ~= nil then
		rows += BANNER_ROWS
	end
	if state.notice ~= nil then
		rows += BANNER_ROWS
	end
	return rows
end

-- Issues mode's list for view_issues: the issues of the scope, Prefs' view, filters and table sort.
local function issuesModeList(state: BlockState, cx: BlockCx, team: Team?): issueList.IssueList
	local prefs = state.prefs
	return {
		items = state.issues,
		truncated = state.truncated,
		view = prefs.view,
		filters = prefs,
		query = state.query.text,
		sort = prefs.sort,
		sortAsc = prefs.sortAsc,
		selectedId = state.selectedId,
		team = team,
		members = if team ~= nil then team.members else {},
		labels = availableLabels(state, team),
		reloading = state.reloading,
		emptyHelp = if prefs.scope == "mine" then "mine" else "none",
		chromeRows = chromeRows(state, cx),
	}
end

-- ─── Project board ──────────────────────────────────────────────────────────

local function teamKeys(project: Project): string
	local keys: { string } = {}
	for _, team in project.teams do
		table.insert(keys, team.key)
	end
	return table.concat(keys, " · ")
end

local function projectCardFoot(project: Project, now: number): Node
	local lead = project.lead
	local target = project.targetDate
	local children = compact({
		ui.node("text", {
			key = "progress",
			role = "linear.project-progress",
			spans = { ui.span(model.progressLabel(project.progress), "muted") },
		}),
		if target ~= nil
			then ui.node("row", { key = "target", role = "linear.project-target", gap = "xs", align = "center" }, {
				ui.node("icon", { key = "icon", name = "calendar", tone = "muted" }),
				ui.node("text", {
					key = "date",
					title = "Target date",
					spans = { ui.span(model.shortDate(target, now), "muted") },
				}),
			})
			else nil,
		ui.node("row", { key = "spacer", grow = 1 }),
		if lead ~= nil
			then ui.node("text", {
				key = "lead",
				role = "linear.project-lead",
				title = lead.name,
				spans = { ui.span(lead.displayName, "muted") },
				max = { w = "14ch" },
			})
			else nil,
	}, 4)
	return ui.node("row", { key = "foot", gap = "sm", align = "start" }, children)
end

local function projectCard(project: Project, selectedId: string?, now: number): Node
	local head = ui.node(
		"row",
		{ key = "head", gap = "xs" },
		compact({
			ui.node("text", {
				key = "teams",
				role = "linear.project-teams",
				spans = { ui.span(teamKeys(project), "mono muted") },
			}),
			ui.node("row", { key = "spacer", grow = 1 }),
			healthBadge(project.health),
		}, 3)
	)
	return ui.node("col", {
		key = project.id,
		role = "linear.project-card",
		gap = "xs",
		mark = if project.id == selectedId then "selected" else nil,
		actions = { click = `open-project={project.id}` },
	}, {
		head,
		ui.node("text", {
			key = "title",
			role = "linear.card-title",
			max = { h = "2lines" },
			spans = { project.name },
		}),
		projectCardFoot(project, now),
	})
end

local function projectColumn(column: ProjectColumn, selectedId: string?, lines: number, now: number): Node
	local cards: { Node } = {}
	for _, project in column.projects do
		table.insert(cards, projectCard(project, selectedId, now))
	end
	return parts.columnNode({
		id = column.id,
		title = column.title,
		kind = column.statusType,
		tone = PROJECT_STATUS_TONES[column.statusType] or "muted",
		cards = cards,
		none = "No projects",
	}, lines)
end

local function projectBoard(state: BlockState, cx: BlockCx, visible: { Project }, now: number): Node
	local columns = model.projectColumns(visible, state.prefs, state.projects.statuses)
	local lines = parts.columnLines(cx, chromeRows(state, cx))
	local children: { Node } = {}
	for _, column in columns do
		table.insert(children, projectColumn(column, state.projects.selectedId, lines, now))
	end
	return parts.boardRow(children)
end

-- ─── Table ──────────────────────────────────────────────────────────────────

local PROJECT_TABLE_COLUMNS: { Col } = {
	{ id = "name", head = "Name", grow = 1, priority = 9 },
	{ id = "status", head = "Status", priority = 7 },
	{ id = "health", head = "Health", priority = 6 },
	{ id = "lead", head = "Lead", priority = 4 },
	{ id = "target", head = "Target", priority = 3 },
	{ id = "progress", head = "Progress", align = "end", priority = 5 },
	{ id = "updated", head = "Updated", align = "end", priority = 2 },
}

local function projectTableRow(project: Project, now: number): TableRow
	local lead = project.lead
	local health = project.health
	local healthTone = if health ~= nil then HEALTH_TONES[health] else nil
	local target = project.targetDate
	return {
		id = project.id,
		cells = {
			project.name,
			{ text = project.status.name, dot = PROJECT_STATUS_TONES[project.status.type] or "muted" },
			if health ~= nil and healthTone ~= nil
				then { badge = { text = model.healthLabel(health), tone = healthTone } }
				else "",
			if lead ~= nil then lead.displayName else "",
			if target ~= nil then model.shortDate(target, now) else "",
			model.progressLabel(project.progress),
			model.relativeTime(project.updatedAt, now),
		},
	}
end

local function projectTable(state: BlockState, visible: { Project }, now: number): Node
	local prefs = state.prefs
	local rows: { TableRow } = {}
	for _, project in model.sortProjects(visible, prefs.projectSort, prefs.projectSortAsc) do
		table.insert(rows, projectTableRow(project, now))
	end
	local node = ui.table(PROJECT_TABLE_COLUMNS, rows, { selectable = true, selected = state.projects.selectedId })
	return with(node, { key = "table", role = "linear.table" })
end

-- ─── Content ────────────────────────────────────────────────────────────────

local function projectEmptyState(state: BlockState): { Node }
	local filtered = projectFiltersActive(state)
	local buttons: { Node } = {}
	if filtered then
		table.insert(buttons, parts.clearFiltersEmptyButton())
	elseif state.prefs.projectView ~= "all" then
		table.insert(buttons, parts.emptyAllButton())
	end
	return parts.withEmptyActions({ parts.emptyNode(filtered, "projects") }, buttons)
end

local function projectContent(state: BlockState, cx: BlockCx, visible: { Project }, now: number): { Node }
	if state.reloading then
		return { reloadingNode(state) }
	end
	if #visible == 0 then
		return projectEmptyState(state)
	end
	local prefs = state.prefs
	if prefs.layout == "table" then
		return {
			parts.sortBar(PROJECT_SORT_COLUMNS, prefs.projectSort, prefs.projectSortAsc),
			projectTable(state, visible, now),
		}
	end
	return { projectBoard(state, cx, visible, now) }
end

local function readyChildren(state: BlockState, cx: BlockCx): { Node }
	local now = os.time()
	local viewerId = viewerIdOf(state)
	local filters: Node
	local body: { Node }
	if inProjects(state) then
		local visible = model.visibleProjects(state.projects.items, state.prefs, state.projects.query.text, viewerId)
		filters = projectFilterRow(state, #visible)
		body = projectContent(state, cx, visible, now)
	else
		local list = issuesModeList(state, cx, selectedTeam(state))
		local visible = issueList.visible(state, list)
		filters = issueList.filterRow(state, list, #visible)
		body = issueList.content(state, cx, list, visible, now)
	end
	local failure = state.error
	local notice = state.notice
	local children = compact({
		topBar(state, now),
		filters,
		if failure ~= nil then banner("error", "linear.error", "error", "x-circle", failure) else nil,
		if notice ~= nil then banner("notice", "linear.notice", "success", "check", notice) else nil,
	}, 4)
	for _, node in body do
		table.insert(children, node)
	end
	return children
end

-- ─── Public API ─────────────────────────────────────────────────────────────

function view.render(state: BlockState, cx: BlockCx): BlockView
	local children: { Node }
	local page = if inProjects(state) then state.projectPage else nil
	if state.phase == "setup" then
		children = { setupCard(state) }
	elseif state.phase == "loading" then
		children = { loadingNode() }
	elseif page ~= nil then
		-- The project page replaces the list (top bar and filter row included).
		children = projectPage.render(state, page, cx)
	else
		children = readyChildren(state, cx)
	end
	return {
		main = ui.node("col", { role = "linear.app", gap = "md" }, children),
		-- The issue drawer and create dialog belong to issues mode; in projects mode the drawer opens only over the
		-- project page's Issues tab.
		layer = if state.phase == "ready"
				and inProjects(state)
				and model.issuesTab(state) == nil
			then nil
			else detail.layer(state, cx),
	}
end

function view.fieldId(name: string): string
	if name == "search" then
		return SEARCH_FIELD_ID
	elseif name == "setup" then
		return SETUP_FIELD_ID
	end
	return projectPage.fieldId(name) or detail.fieldId(name) or ""
end

function view.fieldName(id: string): string?
	if id == SEARCH_FIELD_ID then
		return "search"
	elseif id == SETUP_FIELD_ID then
		return "setup"
	end
	return projectPage.fieldName(id) or detail.fieldName(id)
end

return view
