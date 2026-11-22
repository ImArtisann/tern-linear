--!strict
-- The project page in the `main` region: a header (Back, name, status, health, Open in Linear, refresh), the tab bar
-- and the open tab's content. It replaces the list while `BlockState.projectPage` is set.
-- Pure: reads the block state, never mutates it. The tab bar lists model.PROJECT_TABS; TAB_CONTENT renders each tab.
-- The Issues tab renders its list with view_issues, the issue list of issues mode.

local issueList = require("./view_issues")
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

-- Node ids are `<parent id>.<key>` from the region root: the Issues tab's search field is the tab root ("tab"),
-- its toolbar ("bar") and the input ("search").
local ISSUES_SEARCH_FIELD = "project-search"
local ISSUES_SEARCH_ID = "main.tab.bar.search"

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

local function sectionHeading(title: string, count: string?): Node
	local spans: { Span | string } = { ui.span(title, "strong") }
	if count ~= nil then
		table.insert(spans, ui.span(`  {count}`, "muted"))
	end
	return ui.node("text", { key = "heading", role = "linear.project-heading", spans = spans })
end

-- ─── Header ─────────────────────────────────────────────────────────────────

-- The sync time and loading state of the tab on screen (the header's Refresh).
local function tabFetchedAt(page: ProjectPageState): number?
	if page.tab == "activity" then
		return page.activityFetchedAt
	elseif page.tab == "issues" then
		return page.issues.fetchedAt
	end
	return page.fetchedAt
end

local function tabLoading(page: ProjectPageState): boolean
	if page.tab == "activity" then
		return page.activityLoading
	elseif page.tab == "issues" then
		return page.issues.loading
	end
	return page.loading
end

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
		-- No list item and no detail: a restored page whose project is outside the list, loading or failed.
		nameNode = muted(
			"name",
			if page.error == nil then "Loading project…" else "Project unavailable",
			"linear.project-name"
		)
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
		-- Refresh reloads the tab on screen: its own loading state and sync time.
		ui.button(parts.syncedLabel(tabFetchedAt(page), now), {
			key = "refresh",
			role = "linear.project-refresh",
			icon = "repeat",
			keys = { "r" },
			busy = tabLoading(page),
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

-- `resolution` is the date's DateResolutionType, known once the detail has loaded.
local function dateValue(date: string?, resolution: string?, now: number): Node
	if date == nil then
		return plain("Not set", true)
	end
	return plain(model.resolvedDate(date, resolution, now))
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
		propRow(
			"start",
			"Start date",
			dateValue(project.startDate, if detail ~= nil then detail.startDateResolution else nil, now)
		),
		propRow(
			"target",
			"Target date",
			dateValue(project.targetDate, if detail ~= nil then detail.targetDateResolution else nil, now)
		),
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
	-- The query fetches the first 50: past that the count is a lower bound.
	local count = if detail == nil then nil elseif detail.milestonesTruncated then `{#list}+` else tostring(#list)
	local children: { Node } = { sectionHeading("Milestones", count) }
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

-- ─── Activity ───────────────────────────────────────────────────────────────

local function userName(user: types.User?): string
	if user == nil then
		return "Linear"
	end
	return if user.displayName ~= "" then user.displayName else user.name
end

-- Who the history's ids resolve to: the viewer, the project's lead and members, the teams' members and the
-- authors already loaded; team names from the team list and the project.
local function activityNames(
	state: BlockState,
	page: ProjectPageState,
	project: Project?,
	activity: types.ProjectActivity
): model.ActivityNames
	local users: { types.User } = {}
	local viewer = state.viewer
	if viewer ~= nil then
		table.insert(users, viewer.user)
	end
	local lead = if project ~= nil then project.lead else nil
	if lead ~= nil then
		table.insert(users, lead)
	end
	local detail = page.detail
	if detail ~= nil then
		table.move(detail.members, 1, #detail.members, #users + 1, users)
	end
	for _, team in state.teams do
		table.move(team.members, 1, #team.members, #users + 1, users)
	end
	for _, update in activity.updates.items do
		local author = update.user
		if author ~= nil then
			table.insert(users, author)
		end
		for _, comment in update.comments do
			local commenter = comment.user
			if commenter ~= nil then
				table.insert(users, commenter)
			end
		end
	end
	local teams: { { id: string, name: string } } = {}
	for _, team in state.teams do
		table.insert(teams, { id = team.id, name = team.name })
	end
	if project ~= nil then
		for _, team in project.teams do
			table.insert(teams, { id = team.id, name = team.name })
		end
	end
	-- History milestone references come with an empty name: the project's milestones name them.
	return model.activityNames(users, teams, if detail ~= nil then detail.milestones else {})
end

-- A relative time ("3d") with the absolute time as its tooltip.
local function timeNode(key: string, at: number, now: number): Node
	return ui.node("text", {
		key = key,
		role = "linear.activity-time",
		title = model.absoluteTime(at),
		spans = { ui.span(model.relativeSince(at, now), "muted") },
	})
end

local function updateComment(comment: types.Comment, now: number): Node
	return ui.node("col", { key = comment.id, role = "linear.activity-comment", gap = "xs" }, {
		ui.node("row", { key = "head", role = "linear.comment-head", gap = "sm" }, {
			ui.node("text", { key = "author", spans = { ui.span(userName(comment.user), "strong") } }),
			timeNode("time", model.epoch(comment.createdAt) or 0, now),
		}),
		with(ui.md(text.safeMarkdown(comment.body)), { key = "body", role = "linear.comment-body" }),
	})
end

-- One project update: author, health, time and edited marker over the Markdown body; the comment count toggles
-- the loaded comments.
local function updateNode(update: types.ProjectUpdate, page: ProjectPageState, now: number): Node
	local head: { Node } = {
		ui.node("text", {
			key = "author",
			role = "linear.activity-author",
			spans = { ui.span(userName(update.user), "strong") },
		}),
	}
	local badge = parts.healthBadge(update.health)
	if badge ~= nil then
		table.insert(head, with(badge, { role = "linear.activity-health" }))
	end
	-- The edited marker and the time sit at the end, where the events show their time.
	table.insert(head, ui.node("row", { key = "spacer", grow = 1 }))
	local edited = update.editedAt
	local editedAt = if edited ~= nil then model.epoch(edited) else nil
	if editedAt ~= nil then
		table.insert(
			head,
			ui.node("text", {
				key = "edited",
				role = "linear.activity-edited",
				title = `Edited {model.absoluteTime(editedAt)}`,
				spans = { ui.span("edited ·", "muted") },
			})
		)
	end
	table.insert(head, timeNode("time", model.epoch(update.createdAt) or 0, now))
	local children: { Node } = {
		ui.node(
			"row",
			{ key = "head", role = "linear.activity-head", gap = "sm", align = "center", wrap = true },
			head
		),
		with(ui.md(text.safeMarkdown(update.body)), { key = "body", role = "linear.activity-body" }),
	}
	if update.commentCount > 0 then
		local expanded = page.expandedUpdates[update.id] == true
		local count = update.commentCount
		table.insert(
			children,
			ui.button(if count == 1 then "1 comment" else `{count} comments`, {
				key = "comments-toggle",
				role = "linear.activity-comments-toggle",
				variant = "quiet",
				size = "sm",
				on = expanded,
				actions = { click = `activity-comments={update.id}` },
			})
		)
		if expanded then
			local thread: { Node } = {}
			for _, comment in update.comments do
				table.insert(thread, updateComment(comment, now))
			end
			local hidden = count - #update.comments
			if hidden > 0 then
				table.insert(thread, muted("more", `{hidden} more in Linear`, "linear.activity-comments-more"))
			end
			table.insert(
				children,
				ui.node("col", { key = "comments", role = "linear.activity-comments", gap = "sm" }, thread)
			)
		end
	end
	return ui.node("col", {
		key = update.id,
		role = "linear.activity-update",
		mark = update.health or "none",
		gap = "xs",
	}, children)
end

-- One history event: "<actor> <what>" and the time.
local function eventNode(id: string, event: model.HistoryEvent, now: number): Node
	local spans: { Span | string } = {}
	local actor = event.actor
	if actor ~= nil then
		table.insert(spans, ui.span(actor, "strong"))
		table.insert(spans, ` {event.text}`)
	else
		table.insert(spans, event.text)
	end
	return ui.node(
		"row",
		{ key = id, role = "linear.activity-event", mark = event.kind, gap = "sm", align = "start" },
		{
			ui.node("text", { key = "text", role = "linear.activity-text", grow = 1, basis = 0, spans = spans }),
			timeNode("time", event.time, now),
		}
	)
end

-- The Activity tab: updates and history events in one newest-first feed, `Load more` for older pages.
local function activityTab(
	state: BlockState,
	page: ProjectPageState,
	project: Project?,
	_cx: BlockCx,
	now: number
): Node
	local children: { Node } = {}
	local failure = page.activityError
	if failure ~= nil then
		table.insert(children, parts.banner("activity-error", "linear.activity-error", "error", "x-circle", failure))
	end
	local activity = page.activity
	if activity == nil then
		-- Nothing loaded: the loading line only while a shown load is pending (a retry after an error keeps the error).
		-- A failed first load shows the tab's error, or nothing beyond the banner when the failure went to
		-- `state.error` (rate, auth with an env key).
		if page.activityLoading and failure == nil then
			table.insert(children, loadingLine("loading", "linear.activity-loading"))
		end
		return ui.node("col", { key = "tab", role = "linear.activity", gap = "sm" }, children)
	end
	local timeline = model.activityTimeline(activity, activityNames(state, page, project, activity), now)
	if #timeline.items == 0 and not timeline.more then
		table.insert(children, muted("empty", "No activity yet", "linear.activity-empty"))
	end
	for _, item in timeline.items do
		local update = item.update
		local event = item.event
		if update ~= nil then
			table.insert(children, updateNode(update, page, now))
		elseif event ~= nil then
			table.insert(children, eventNode(item.id, event, now))
		end
	end
	if timeline.more then
		table.insert(
			children,
			ui.button("Load more", {
				key = "more",
				role = "linear.activity-more",
				variant = "quiet",
				busy = page.activityPaging,
				disabled = page.activityLoading,
				actions = { click = "activity-more" },
			})
		)
	end
	return ui.node("col", { key = "tab", role = "linear.activity", gap = "sm" }, children)
end

-- ─── Issues ─────────────────────────────────────────────────────────────────

-- Pane rows above the cards: header, tab bar, toolbar, filter row, column heads and their gaps.
local ISSUES_CHROME_ROWS = 16
local BANNER_ROWS = 3

-- The assignee and label options: the members and labels of the teams the loaded issues belong to.
local function issueOptions(state: BlockState, issues: { types.Issue }): ({ types.User }, { types.Label })
	local members: { types.User } = {}
	local labels: { types.Label } = {}
	local seenMember: { [string]: boolean } = {}
	local seenLabel: { [string]: boolean } = {}
	for _, team in model.issueTeams(issues, state.teams) do
		for _, member in team.members do
			if not seenMember[member.id] then
				seenMember[member.id] = true
				table.insert(members, member)
			end
		end
		for _, label in team.labels do
			if not seenLabel[label.id] then
				seenLabel[label.id] = true
				table.insert(labels, label)
			end
		end
	end
	table.sort(members, function(a, b)
		return string.lower(a.displayName) < string.lower(b.displayName)
	end)
	table.sort(labels, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return members, labels
end

-- View switch, search and layout toggle of the tab (the top bar's controls for its own list).
local function issuesToolbar(state: BlockState, tab: types.ProjectIssuesState): Node
	local query = tab.query
	return ui.node("row", { key = "bar", role = "linear.project-issues-bar", gap = "sm", wrap = true }, {
		parts.viewSwitcher(tab.view),
		ui.node("input", {
			key = "search",
			role = "linear.search",
			text = query.text,
			cursor = query.cursor,
			anchor = query.anchor,
			placeholder = "Search issues",
			icon = "search",
			keys = { "/" },
			variant = "field",
			grow = 1,
			min = { w = "16ch" },
			max = { w = "40ch" },
		}),
		parts.layoutSwitcher(state.prefs.layout),
	})
end

-- The Issues tab: the toolbar, then issues mode's filter row and board or table over the project's issues.
local function issuesTab(state: BlockState, page: ProjectPageState, _project: Project?, cx: BlockCx, now: number): Node
	local tab = page.issues
	local banners = 0
	for _, shown in { state.error ~= nil, state.notice ~= nil, page.error ~= nil, tab.error ~= nil } do
		if shown then
			banners += 1
		end
	end
	local members, labels = issueOptions(state, tab.items)
	-- No load succeeded and no shown load runs (every first load is a shown one): the first load failed, whether its
	-- error shows in the tab or in the page's banner (an env key's auth failure, a rate limit).
	local failedFirst = tab.fetchedAt == nil and not tab.loading
	local list: issueList.IssueList = {
		items = tab.items,
		truncated = tab.truncated,
		view = tab.view,
		filters = tab,
		query = tab.query.text,
		sort = tab.sort,
		sortAsc = tab.sortAsc,
		selectedId = tab.selectedId,
		team = nil,
		members = members,
		labels = labels,
		reloading = tab.loading,
		emptyHelp = "all",
		chromeRows = ISSUES_CHROME_ROWS + banners * BANNER_ROWS,
	}
	local visible = issueList.visible(state, list)
	local children: { Node } = { issuesToolbar(state, tab), issueList.filterRow(state, list, #visible) }
	local failure = tab.error
	if failure ~= nil then
		table.insert(
			children,
			parts.banner("issues-error", "linear.project-issues-error", "error", "x-circle", failure)
		)
	end
	-- A first load that failed has nothing to show but the banners.
	if not failedFirst then
		for _, node in issueList.content(state, cx, list, visible, now) do
			table.insert(children, node)
		end
	end
	return ui.node("col", { key = "tab", role = "linear.project-issues", gap = "md" }, children)
end

type TabRenderer = (BlockState, ProjectPageState, Project?, BlockCx, number) -> Node

-- One renderer per tab id of model.PROJECT_TABS.
local TAB_CONTENT: { [string]: TabRenderer } = {
	overview = overview,
	activity = activityTab,
	issues = issuesTab,
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

function projectPage.fieldId(name: string): string?
	return if name == ISSUES_SEARCH_FIELD then ISSUES_SEARCH_ID else nil
end

function projectPage.fieldName(id: string): string?
	return if id == ISSUES_SEARCH_ID then ISSUES_SEARCH_FIELD else nil
end

return projectPage
