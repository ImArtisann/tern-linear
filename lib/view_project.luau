--!strict
-- The project page in the `main` region: a header (Back, name, status, health, Open in Linear, refresh), the tab bar
-- and the open tab's content. It replaces the list while `BlockState.projectPage` is set.
-- Pure: reads the block state, never mutates it. The tab bar lists model.PROJECT_TABS; TAB_CONTENT renders each tab.

local model = require("./model")
local parts = require("./view_parts")
local text = require("./text")
local types = require("./types")

type BlockState = types.BlockState
type Project = types.Project
type ProjectDetail = types.ProjectDetail
type ProjectMilestone = types.ProjectMilestone
type ProjectPageState = types.ProjectPageState

local ui = tern.ui
local with = parts.with
local compact = parts.compact

local projectPage = {}

-- From this pane width (columns) up the Overview is two columns: content beside a properties sidebar.
local WIDE_COLS = 110
local SIDEBAR_WIDTH = "40ch"
local MAX_MEMBER_NAMES = 6

-- Span tokens per ProjectMilestoneStatus.
local MILESTONE_TOKENS: { [string]: string } = {
	done = "success",
	next = "info",
	overdue = "error",
	unstarted = "muted",
}

-- What the page shows for its project: the loaded detail, else the list item (shown at once while loading).
local function pageProject(state: BlockState, page: ProjectPageState): Project?
	local detail = page.detail
	if detail ~= nil then
		return detail.project
	end
	for _, project in state.projects.items do
		if project.id == page.projectId then
			return project
		end
	end
	return nil
end

local function muted(key: string, label: string, role: string?): Node
	return ui.node("text", { key = key, role = role, spans = { ui.span(label, "muted") } })
end

local function loadingLine(key: string, role: string): Node
	return ui.node("shimmer", { key = key, role = role, text = "Loading…" })
end

local function sectionHeading(title: string, count: number?): Node
	local spans: { Span | string } = { ui.span(title, "strong") }
	if count ~= nil then
		table.insert(spans, ui.span(`  {count}`, "muted"))
	end
	return ui.node("text", { key = "heading", role = "linear.project-heading", spans = spans })
end

-- ─── Header ─────────────────────────────────────────────────────────────────

local function header(page: ProjectPageState, project: Project?, now: number): Node
	local nameNode: Node
	local statusNode: Node? = nil
	local linkButtons: { Node } = {}
	if project ~= nil then
		nameNode = ui.node("text", {
			key = "name",
			role = "linear.project-name",
			title = project.name,
			spans = { ui.span(project.name, "strong") },
		})
		statusNode = ui.node("row", { key = "status", role = "linear.project-status", gap = "xs", align = "center" }, {
			parts.statusDot(parts.PROJECT_STATUS_TONES[project.status.type] or "muted", project.status.type),
			ui.node("text", { key = "label", spans = { ui.span(project.status.name, "muted") } }),
		})
		linkButtons = {
			ui.button("Open in Linear", {
				key = "open",
				role = "linear.project-open-url",
				icon = "link",
				keys = { "o" },
				actions = { click = `open-project-url={project.id}` },
			}),
			ui.button("", {
				key = "copy",
				role = "linear.project-copy-url",
				icon = "copy",
				variant = "quiet",
				title = "Copy link",
				actions = { click = `copy-project-url={project.id}` },
			}),
		}
	else
		nameNode = muted("name", "Loading project…", "linear.project-name")
	end
	local children = compact({
		ui.button("Back", {
			key = "back",
			role = "linear.project-back",
			icon = "arrow-left",
			variant = "quiet",
			keys = { "esc" },
			actions = { click = "project-back" },
		}),
		nameNode,
		statusNode,
		if project ~= nil then parts.healthBadge(project.health) else nil,
		ui.node("row", { key = "spacer", grow = 1 }),
		linkButtons[1],
		linkButtons[2],
		ui.button(parts.syncedLabel(page.fetchedAt, now), {
			key = "refresh",
			role = "linear.project-refresh",
			icon = "repeat",
			keys = { "r" },
			busy = page.loading,
			actions = { click = "refresh-project" },
		}),
	}, 8)
	return ui.node("row", { key = "page-head", role = "linear.project-header", gap = "sm", wrap = true }, children)
end

local function tabBar(page: ProjectPageState): Node
	local buttons: { Node } = {}
	for _, tab in model.PROJECT_TABS do
		table.insert(
			buttons,
			ui.button(tab.label, {
				key = `tab-{tab.id}`,
				role = `linear.project-tab-{tab.id}`,
				on = page.tab == tab.id,
				actions = { click = `project-tab={tab.id}` },
			})
		)
	end
	return ui.node("buttons", { key = "tabs", role = "linear.project-tabs" }, buttons)
end

-- ─── Overview: properties ───────────────────────────────────────────────────

local function propRow(key: string, label: string, value: Node): Node
	return ui.node("row", { key = `prop-{key}`, role = "linear.project-prop", gap = "sm" }, {
		muted("label", label),
		with(value, { key = "value" }),
	})
end

local function plain(label: string, quiet: boolean?): Node
	return ui.text({ if quiet then ui.span(label, "muted") else label })
end

-- Health badge, then when the last project update set it.
local function healthValue(project: Project, detail: ProjectDetail?, now: number): Node
	local badge = parts.healthBadge(project.health)
	if badge == nil then
		return plain("No update", true)
	end
	local since = if detail ~= nil then detail.healthUpdatedAt else nil
	local children: { Node } = { badge }
	if since ~= nil then
		local relative = model.relativeTime(since, now)
		local when = if string.match(relative, "^%d+[mhd]$") ~= nil then `{relative} ago` else relative
		table.insert(children, muted("since", `updated {when}`))
	end
	return ui.node("row", { gap = "xs", align = "center" }, children)
end

local function priorityValue(project: Project): Node
	local tone = parts.PRIORITY_TONES[project.priority]
	if tone == nil then
		return plain(model.priorityLabel(project.priority), true)
	end
	return ui.badge(model.priorityLabel(project.priority), tone)
end

local function dateValue(date: string?, now: number): Node
	if date == nil then
		return plain("Not set", true)
	end
	return plain(model.shortDate(date, now))
end

local function teamsValue(project: Project): Node
	if #project.teams == 0 then
		return plain("No teams", true)
	end
	local names: { string } = {}
	for _, team in project.teams do
		table.insert(names, team.name)
	end
	return ui.node("text", { title = table.concat(names, ", "), spans = { table.concat(names, ", ") } })
end

local function membersValue(detail: ProjectDetail?): Node
	if detail == nil then
		return plain("…", true)
	end
	if #detail.members == 0 then
		return plain("No members", true)
	end
	local names: { string } = {}
	for _, member in detail.members do
		table.insert(names, member.displayName)
	end
	return ui.node("text", {
		title = table.concat(names, ", "),
		spans = { model.namesLabel(names, MAX_MEMBER_NAMES) },
	})
end

local function labelsValue(detail: ProjectDetail): Node
	local chips: { Node } = {}
	for _, label in detail.labels do
		table.insert(chips, with(ui.badge(label.name, "neutral"), { key = label.id }))
	end
	return ui.node("row", { role = "linear.project-labels", gap = "xs", wrap = true }, chips)
end

local function properties(project: Project, detail: ProjectDetail?, now: number): Node
	local lead = project.lead
	local rows: { Node } = {
		propRow(
			"status",
			"Status",
			ui.node("row", { gap = "xs", align = "center" }, {
				parts.statusDot(parts.PROJECT_STATUS_TONES[project.status.type] or "muted", project.status.type),
				ui.node("text", { key = "label", spans = { project.status.name } }),
			})
		),
		propRow("health", "Health", healthValue(project, detail, now)),
		propRow("priority", "Priority", priorityValue(project)),
		propRow("lead", "Lead", if lead ~= nil then plain(lead.displayName) else plain("No lead", true)),
		propRow("members", "Members", membersValue(detail)),
		propRow("teams", "Teams", teamsValue(project)),
		propRow("start", "Start date", dateValue(project.startDate, now)),
		propRow("target", "Target date", dateValue(project.targetDate, now)),
		propRow(
			"progress",
			"Progress",
			with(ui.meter(project.progress, model.progressLabel(project.progress)), { role = "linear.project-meter" })
		),
	}
	if detail ~= nil and #detail.labels > 0 then
		table.insert(rows, propRow("labels", "Labels", labelsValue(detail)))
	end
	return ui.node("col", { key = "props", role = "linear.project-props", gap = "xs" }, rows)
end

-- ─── Overview: description and milestones ───────────────────────────────────

local function description(page: ProjectPageState): Node?
	local detail = page.detail
	if detail == nil then
		return if page.error == nil then loadingLine("description", "linear.project-description-loading") else nil
	end
	if string.match(detail.content, "%S") == nil then
		return muted("description", "No description", "linear.project-description-empty")
	end
	return with(ui.md(text.safeMarkdown(detail.content)), { key = "description", role = "linear.project-description" })
end

-- One milestone, keyed by its id (a later layer attaches its click action here): the name over its status and
-- target date, the progress at the end.
local function milestoneRow(milestone: ProjectMilestone, now: number): Node
	local token = MILESTONE_TOKENS[milestone.status] or MILESTONE_TOKENS.unstarted
	local target = milestone.targetDate
	local meta = ui.node("row", { key = "meta", gap = "xs" }, {
		ui.node("text", {
			key = "status",
			role = "linear.milestone-status",
			spans = { ui.span(model.milestoneStatusLabel(milestone.status), token) },
		}),
		ui.node("text", {
			key = "target",
			role = "linear.milestone-target",
			title = "Target date",
			spans = { ui.span(if target ~= nil then `· {model.shortDate(target, now)}` else "· No target", "muted") },
		}),
	})
	return ui.node("row", {
		key = milestone.id,
		role = "linear.milestone",
		mark = milestone.status,
		gap = "sm",
		align = "start",
	}, {
		ui.node("text", { key = "icon", role = "linear.milestone-icon", spans = { ui.span("◆", token) } }),
		ui.node("col", { key = "text", gap = "xs", grow = 1, basis = 0 }, {
			ui.node("text", {
				key = "name",
				role = "linear.milestone-name",
				title = milestone.name,
				spans = { milestone.name },
			}),
			meta,
		}),
		ui.node("text", {
			key = "progress",
			role = "linear.milestone-progress",
			spans = { ui.span(model.progressLabel(milestone.progress), "muted") },
		}),
	})
end

local function milestones(page: ProjectPageState, now: number): Node?
	local detail = page.detail
	if detail == nil and page.error ~= nil then
		return nil
	end
	local list: { ProjectMilestone } = if detail ~= nil then detail.milestones else {}
	local children: { Node } = { sectionHeading("Milestones", if detail ~= nil then #list else nil) }
	if detail == nil then
		table.insert(children, loadingLine("loading", "linear.milestones-loading"))
	elseif #list == 0 then
		table.insert(children, muted("none", "No milestones", "linear.milestones-empty"))
	else
		for _, milestone in list do
			table.insert(children, milestoneRow(milestone, now))
		end
	end
	return ui.node("col", { key = "milestones", role = "linear.milestones", gap = "xs" }, children)
end

local function overview(_state: BlockState, page: ProjectPageState, project: Project?, cx: BlockCx, now: number): Node
	if project == nil then
		return if page.error == nil
			then loadingLine("tab", "linear.project-loading")
			else muted("tab", "The project could not be loaded.", "linear.project-unavailable")
	end
	local summary = if string.match(project.summary, "%S") ~= nil
		then ui.node("text", {
			key = "summary",
			role = "linear.project-summary",
			spans = { ui.span(project.summary, "muted") },
		})
		else nil
	-- The sidebar holds the properties and the milestones, so both show above a long document.
	local sidebar = ui.node(
		"col",
		{ key = "sidebar", role = "linear.project-sidebar", gap = "sm" },
		compact({ sectionHeading("Properties", nil), properties(project, page.detail, now), milestones(page, now) }, 3)
	)
	if cx.cols >= WIDE_COLS then
		local content = ui.node(
			"col",
			{ key = "content", role = "linear.project-content", gap = "md", grow = 1, basis = 0 },
			compact({ summary, description(page) }, 2)
		)
		return ui.node(
			"row",
			{ key = "tab", role = "linear.project-overview", mark = "wide", gap = "md", align = "start" },
			{
				content,
				with(sidebar, { min = { w = SIDEBAR_WIDTH }, max = { w = SIDEBAR_WIDTH } }),
			}
		)
	end
	-- Narrow: one column, the summary first, then the properties and milestones, then the document.
	return ui.node(
		"col",
		{ key = "tab", role = "linear.project-overview", mark = "stacked", gap = "md" },
		compact({ summary, sidebar, description(page) }, 3)
	)
end

type TabRenderer = (BlockState, ProjectPageState, Project?, BlockCx, number) -> Node

-- One renderer per tab id of model.PROJECT_TABS.
local TAB_CONTENT: { [string]: TabRenderer } = {
	overview = overview,
}

-- ─── Public API ─────────────────────────────────────────────────────────────

-- The `main` children while the project page is open.
function projectPage.render(state: BlockState, page: ProjectPageState, cx: BlockCx): { Node }
	local now = os.time()
	local project = pageProject(state, page)
	local failure = state.error
	local notice = state.notice
	local pageError = page.error
	local children = compact({
		header(page, project, now),
		tabBar(page),
		if failure ~= nil then parts.banner("error", "linear.error", "error", "x-circle", failure) else nil,
		if pageError ~= nil and pageError ~= failure
			then parts.banner("page-error", "linear.project-error", "error", "x-circle", pageError)
			else nil,
		if notice ~= nil then parts.banner("notice", "linear.notice", "success", "check", notice) else nil,
	}, 5)
	local renderTab: TabRenderer = TAB_CONTENT[page.tab] or overview
	table.insert(children, renderTab(state, page, project, cx, now))
	return children
end

return projectPage
