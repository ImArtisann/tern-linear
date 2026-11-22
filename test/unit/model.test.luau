--!strict
-- Unit tests for lib/model.luau: filtering, ordering, columns, server filters, dates. Run with the `luau` CLI.

local model = require("../../lib/model")
local types = require("../../lib/types")

local failures = 0

local function check(name: string, condition: boolean)
	if condition then
		print("ok   " .. name)
	else
		failures += 1
		print("FAIL " .. name)
	end
end

local function ids(issues: { types.Issue }): string
	local out: { string } = {}
	for _, issue in issues do
		table.insert(out, issue.identifier)
	end
	return table.concat(out, " ")
end

local function state(id: string, name: string, stateType: string, position: number): types.WorkflowState
	return { id = id, name = name, type = stateType, color = "#888888", position = position }
end

local BACKLOG = state("s-backlog", "Backlog", "backlog", 0)
local TODO = state("s-todo", "Todo", "unstarted", 0)
local DOING = state("s-doing", "In Progress", "started", 0)
local REVIEW = state("s-review", "In Review", "started", 1)
local DONE = state("s-done", "Done", "completed", 0)
local CANCELED = state("s-canceled", "Canceled", "canceled", 0)
local DUPLICATE = state("s-dup", "Duplicate", "duplicate", 1)

local team: types.Team = {
	id = "t-eng",
	key = "ENG",
	name = "Engineering",
	color = nil,
	cyclesEnabled = false,
	triageEnabled = false,
	estimation = "notUsed",
	defaultStateId = nil,
	states = { BACKLOG, TODO, DOING, REVIEW, DONE, CANCELED, DUPLICATE },
	labels = {},
	members = {},
}

local function user(id: string, name: string): types.User
	return { id = id, name = name, displayName = name, avatarUrl = nil, active = true }
end

local ME = user("u-me", "Peter Pan")
local ANA = user("u-ana", "Ana")

type IssueOverrides = {
	number: number?,
	title: string?,
	state: types.WorkflowState?,
	priority: number?,
	sortOrder: number?,
	teamKey: string?,
	assignee: types.User?,
	labels: { types.Label }?,
	relations: { types.Relation }?,
	updatedAt: string?,
}

local function issue(id: string, overrides: IssueOverrides?): types.Issue
	local o: IssueOverrides = overrides or {}
	local teamKey = o.teamKey or "ENG"
	local number = o.number or 1
	return {
		id = id,
		identifier = `{teamKey}-{number}`,
		number = number,
		title = o.title or "Untitled",
		description = nil,
		priority = o.priority or 0,
		priorityLabel = "",
		estimate = nil,
		url = "https://linear.app/x",
		branchName = "branch",
		createdAt = "2025-01-01T00:00:00.000Z",
		updatedAt = o.updatedAt or "2025-01-01T00:00:00.000Z",
		completedAt = nil,
		canceledAt = nil,
		archivedAt = nil,
		dueDate = nil,
		sortOrder = o.sortOrder or 0,
		state = o.state or TODO,
		teamId = "t-" .. string.lower(teamKey),
		teamKey = teamKey,
		assignee = o.assignee,
		creator = nil,
		labels = o.labels or {},
		project = nil,
		cycle = nil,
		parent = nil,
		children = {},
		relations = o.relations or {},
		comments = nil,
		detailed = false,
	}
end

local function prefs(overrides: { [string]: any }?): types.Prefs
	local p: { [string]: any } = {
		scope = "team",
		teamId = "t-eng",
		view = "active",
		layout = "board",
		sort = "identifier",
		sortAsc = true,
	}
	for key, value in overrides or {} do
		p[key] = value
	end
	return p :: any
end

local function ref(id: string, stateType: string): types.IssueRef
	return { id = id, identifier = id, title = id, stateType = stateType, stateName = nil }
end

-- ─── blocked ────────────────────────────────────────────────────────────────

local blockedByOpen = issue(
	"a",
	{ relations = { { id = "r1", type = "blocks", direction = "incoming", other = ref("open", "started") } } }
)
local blockedByDone = issue(
	"b",
	{ relations = { { id = "r2", type = "blocks", direction = "incoming", other = ref("done", "completed") } } }
)
local blocking =
	issue("c", { relations = { { id = "r3", type = "blocks", direction = "outgoing", other = ref("x", "started") } } })
local related =
	issue("d", { relations = { { id = "r4", type = "related", direction = "incoming", other = ref("y", "started") } } })

check("an open incoming blocker blocks", model.isBlocked(blockedByOpen))
check("a resolved blocker does not block", not model.isBlocked(blockedByDone))
check("blocking someone else is not blocked", not model.isBlocked(blocking))
check("a plain relation is not a blocker", not model.isBlocked(related))
check(
	"blockers lists the open blockers only",
	#model.blockers(blockedByOpen) == 1 and #model.blockers(blockedByDone) == 0
)

-- ─── server filter ──────────────────────────────────────────────────────────

local mineFilter: any = model.serverFilter(prefs({ scope = "mine", teamId = nil, view = "backlog" }))
check("mine scope filters on the viewer", mineFilter["and"][1].assignee.isMe.eq == true)
check(
	"backlog view filters the backlog type",
	mineFilter["and"][2].state.type["in"][1] == "backlog" and #mineFilter["and"][2].state.type["in"] == 1
)

local teamFilter: any = model.serverFilter(prefs({ view = "active" }))
check("team scope filters on the team id", teamFilter["and"][1].team.id.eq == "t-eng")
local activeTypes: { string } = teamFilter["and"][2].state.type["in"]
check("active view is triage, unstarted and started", table.concat(activeTypes, ",") == "triage,unstarted,started")

local allFilter: any = model.serverFilter(prefs({ view = "all" }))
local either: any = allFilter["and"][2]["or"]
check("all view keeps open issues", table.concat(either[1].state.type.nin, ",") == "completed,canceled,duplicate")
check(
	"all view keeps recently closed issues",
	either[2].completedAt.gt == "-P14D" and either[3].canceledAt.gt == "-P14D"
)

-- ─── visible: filtering and board order ─────────────────────────────────────

local urgent = issue("i1", { number = 1, state = DOING, priority = 1, title = "Urgent fix", assignee = ME })
local low = issue("i2", { number = 2, state = DOING, priority = 4, sortOrder = 5 })
local none = issue("i3", { number = 3, state = DOING, priority = 0, sortOrder = 1 })
local highLater = issue("i4", { number = 4, state = DOING, priority = 2, sortOrder = 9, title = "Search ПРИВЕТ" })
local highEarlier = issue("i5", {
	number = 5,
	state = DOING,
	priority = 2,
	sortOrder = 2,
	labels = { { id = "l-bug", name = "Bug", color = "#f00", isGroup = nil } },
})
local inReview = issue("i6", { number = 6, state = REVIEW, priority = 1, assignee = ANA })
local inTodo = issue("i7", { number = 7, state = TODO, priority = 3 })
local inBacklog = issue("i8", { number = 8, state = BACKLOG, priority = 1 })

local pool = { inReview, none, highLater, inBacklog, urgent, low, inTodo, highEarlier, urgent }

check(
	"visible orders by column, priority, sortOrder and drops duplicates",
	ids(model.visible(pool, prefs(), "", nil)) == "ENG-8 ENG-7 ENG-1 ENG-5 ENG-4 ENG-2 ENG-3 ENG-6"
)
check(
	"query matches titles case-insensitively, Cyrillic included",
	ids(model.visible(pool, prefs(), "urgent", nil)) == "ENG-1"
)
check("query matches the identifier", ids(model.visible(pool, prefs(), "eng-5", nil)) == "ENG-5")
check("query matches label names", ids(model.visible(pool, prefs(), "BUG", nil)) == "ENG-5")
check("query matches the assignee", ids(model.visible(pool, prefs(), "ana", nil)) == "ENG-6")
check("priority filter", ids(model.visible(pool, prefs({ priority = 2 }), "", nil)) == "ENG-5 ENG-4")
check("assignee filter me", ids(model.visible(pool, prefs({ assignee = "me" }), "", "u-me")) == "ENG-1")
check(
	"assignee filter me without a viewer matches nothing",
	ids(model.visible(pool, prefs({ assignee = "me" }), "", nil)) == ""
)
check(
	"assignee filter none",
	ids(model.visible(pool, prefs({ assignee = "none" }), "", nil)) == "ENG-8 ENG-7 ENG-5 ENG-4 ENG-2 ENG-3"
)
check("assignee filter by id", ids(model.visible(pool, prefs({ assignee = "u-ana" }), "", nil)) == "ENG-6")
check("label filter", ids(model.visible(pool, prefs({ labelId = "l-bug" }), "", nil)) == "ENG-5")

-- ─── columns ────────────────────────────────────────────────────────────────

local teamAll = prefs({ view = "all" })
local columns = model.columns(model.visible(pool, teamAll, "", nil), teamAll, team)
local titles: { string } = {}
for _, column in columns do
	table.insert(titles, `{column.title}:{#column.issues}`)
end
check(
	"team columns follow the team's states, empty ones included",
	table.concat(titles, ",") == "Backlog:1,Todo:1,In Progress:5,In Review:1,Done:0,Canceled:0,Duplicate:0"
)
check(
	"team columns carry state ids",
	columns[3].id == "s-doing" and columns[3].stateId == "s-doing" and columns[3].stateType == "started"
)

local activeColumns = model.columns(model.visible(pool, prefs(), "", nil), prefs(), team)
check(
	"active view hides backlog and closed columns",
	#activeColumns == 3 and activeColumns[1].title == "Todo" and activeColumns[3].title == "In Review"
)

local mine = prefs({ scope = "mine", teamId = nil, view = "all" })
local otherTeam =
	issue("o1", { teamKey = "OPS", number = 9, state = state("s-ops-doing", "Doing", "started", 3), priority = 1 })
local dupIssue = issue("o2", { teamKey = "OPS", number = 10, state = DUPLICATE })
local mineColumns = model.columns(model.visible({ low, otherTeam, dupIssue, urgent }, mine, "", nil), mine, nil)
local mineTitles: { string } = {}
for _, column in mineColumns do
	table.insert(mineTitles, `{column.title}:{#column.issues}`)
end
check(
	"mine columns are one per state type with duplicate folded into canceled",
	table.concat(mineTitles, ",") == "Triage:0,Backlog:0,Todo:0,In Progress:3,Done:0,Canceled:1"
)
check(
	"mine columns have no state id",
	mineColumns[4].stateId == nil and mineColumns[4].id == "started" and mineColumns[5].title == "Done"
)
check("mine columns order cards by priority across teams", ids(mineColumns[4].issues) == "ENG-1 OPS-9 ENG-2")

local emptyBoard = model.columns({}, prefs({ view = "backlog" }), team)
check(
	"an empty board keeps its shape",
	#emptyBoard == 1 and emptyBoard[1].title == "Backlog" and #emptyBoard[1].issues == 0
)

-- ─── table sorting ──────────────────────────────────────────────────────────

local rows = {
	issue("t1", {
		teamKey = "ENG",
		number = 10,
		title = "beta",
		priority = 0,
		assignee = ANA,
		state = DONE,
		updatedAt = "2025-03-01T00:00:00Z",
	}),
	issue(
		"t2",
		{ teamKey = "ENG", number = 2, title = "Alpha", priority = 2, state = TODO, updatedAt = "2025-05-01T00:00:00Z" }
	),
	issue("t3", {
		teamKey = "API",
		number = 7,
		title = "gamma",
		priority = 1,
		assignee = ME,
		state = DOING,
		updatedAt = "2025-04-01T00:00:00Z",
	}),
}

check(
	"sort by identifier compares team key then number",
	ids(model.sortTable(rows, "identifier", true)) == "API-7 ENG-2 ENG-10"
)
check("sort by identifier descending", ids(model.sortTable(rows, "identifier", false)) == "ENG-10 ENG-2 API-7")
check("sort by title ignores case", ids(model.sortTable(rows, "title", true)) == "ENG-2 ENG-10 API-7")
check("sort by state follows type rank", ids(model.sortTable(rows, "state", true)) == "ENG-2 API-7 ENG-10")
check(
	"sort by priority puts urgent first and none last",
	ids(model.sortTable(rows, "priority", true)) == "API-7 ENG-2 ENG-10"
)
check("sort by assignee puts unassigned last", ids(model.sortTable(rows, "assignee", true)) == "ENG-10 API-7 ENG-2")
check(
	"sort by updated is newest first when descending",
	ids(model.sortTable(rows, "updated", false)) == "ENG-2 API-7 ENG-10"
)
check("sorting does not mutate its input", ids(rows) == "ENG-10 ENG-2 API-7")

-- ─── workflow states ────────────────────────────────────────────────────────

check(
	"stateFor picks the lowest position of a type",
	(model.stateFor(team, "started") :: types.WorkflowState).id == "s-doing"
)
check(
	"done, todo and started helpers",
	(model.doneState(team) :: types.WorkflowState).id == "s-done"
		and (model.todoState(team) :: types.WorkflowState).id == "s-todo"
		and (model.startedState(team) :: types.WorkflowState).id == "s-doing"
)

local doing = issue("m1", { state = DOING })
check(
	"adjacentState steps forward inside the view",
	(model.adjacentState(team, doing, 1, "active") :: types.WorkflowState).id == "s-review"
)
check(
	"adjacentState steps backward inside the view",
	(model.adjacentState(team, doing, -1, "active") :: types.WorkflowState).id == "s-todo"
)
check(
	"adjacentState stops at the last column",
	model.adjacentState(team, issue("m2", { state = REVIEW }), 1, "active") == nil
)
check(
	"adjacentState stops at the first column",
	model.adjacentState(team, issue("m3", { state = TODO }), -1, "active") == nil
)
check(
	"adjacentState outside the view walks every state",
	(model.adjacentState(team, issue("m4", { state = DONE }), 1, "active") :: types.WorkflowState).id == "s-canceled"
)
check(
	"adjacentState from a closed state skips duplicate",
	model.adjacentState(team, issue("m5", { state = CANCELED }), 1, "active") == nil
)
check(
	"adjacentState in the all view reaches the duplicate state",
	(model.adjacentState(team, issue("m6", { state = CANCELED }), 1, "all") :: types.WorkflowState).id == "s-dup"
)

-- ─── dates ──────────────────────────────────────────────────────────────────

check("epoch of the Unix epoch", model.epoch("1970-01-01T00:00:00Z") == 0)
check("epoch of a known timestamp", model.epoch("2024-03-04T05:06:07Z") == 1709528767)
check("epoch keeps fractional seconds", model.epoch("2024-03-04T05:06:07.250Z") == 1709528767.25)
check("epoch applies a positive offset", model.epoch("2024-03-04T07:06:07+02:00") == 1709528767)
check("epoch applies a negative offset", model.epoch("2024-03-03T23:36:07-05:30") == 1709528767)
check(
	"epoch handles leap days",
	(model.epoch("2024-03-01T00:00:00Z") :: number) - (model.epoch("2024-02-28T00:00:00Z") :: number) == 2 * 86400
)
check("epoch of a bare date", model.epoch("2024-03-04") == 1709510400)
check("epoch rejects garbage", model.epoch("yesterday") == nil and model.epoch("2024-13-01T00:00:00Z") == nil)

local now = model.epoch("2025-06-15T12:00:00Z") :: number
check("relativeTime under a minute is now", model.relativeTime("2025-06-15T11:59:01Z", now) == "now")
check("relativeTime at a minute", model.relativeTime("2025-06-15T11:59:00Z", now) == "1m")
check("relativeTime in minutes", model.relativeTime("2025-06-15T11:55:00Z", now) == "5m")
check("relativeTime at an hour", model.relativeTime("2025-06-15T11:00:00Z", now) == "1h")
check("relativeTime in hours", model.relativeTime("2025-06-15T09:00:00Z", now) == "3h")
check("relativeTime at a day", model.relativeTime("2025-06-14T12:00:00Z", now) == "1d")
check("relativeTime in days", model.relativeTime("2025-06-13T12:00:00Z", now) == "2d")
check("relativeTime keeps days through 30", model.relativeTime("2025-05-16T12:00:00Z", now) == "30d")
check("relativeTime switches to a date after 30 days", model.relativeTime("2025-05-15T12:00:00Z", now) == "May 15")
check("relativeTime adds the year for earlier years", model.relativeTime("2024-03-04T08:00:00Z", now) == "Mar 4, 2024")
check("relativeTime of the future is now", model.relativeTime("2025-06-16T12:00:00Z", now) == "now")

-- ─── identifiers and priorities ─────────────────────────────────────────────

local key, number = model.parseIdentifier("eng-12")
check("parseIdentifier uppercases the team key", key == "ENG" and number == 12)
check("parseIdentifier rejects free text", model.parseIdentifier("fix login") == nil)
check("priorityLabel", model.priorityLabel(1) == "Urgent" and model.priorityLabel(0) == "No priority")
check("typeRank follows STATE_TYPES", model.typeRank("triage") == 1 and model.typeRank("duplicate") == 7)

-- ─── form diff ──────────────────────────────────────────────────────────────

local form: types.Form = {
	kind = "edit",
	issueId = "a",
	focus = 1,
	error = nil,
	fields = {
		{
			name = "title",
			label = "Title",
			kind = "text",
			field = { text = "New title", cursor = 9, anchor = nil },
			value = nil,
			options = nil,
			baseline = "Old title",
			placeholder = nil,
		},
		{
			name = "description",
			label = "Description",
			kind = "multiline",
			field = { text = "same", cursor = 4, anchor = nil },
			value = nil,
			options = nil,
			baseline = "same",
			placeholder = nil,
		},
		{
			name = "priority",
			label = "Priority",
			kind = "choice",
			field = nil,
			value = "2",
			options = {},
			baseline = "0",
			placeholder = nil,
		},
		{
			name = "assignee",
			label = "Assignee",
			kind = "choice",
			field = nil,
			value = "",
			options = {},
			baseline = "",
			placeholder = nil,
		},
	},
}
local diff = model.formDiff(form)
check(
	"formDiff returns only changed fields",
	diff.title == "New title" and diff.priority == "2" and diff.description == nil and diff.assignee == nil
)

-- ─── projects ───────────────────────────────────────────────────────────────

local function pstatus(id: string, name: string, statusType: string, position: number): types.ProjectStatus
	return { id = id, name = name, type = statusType, color = "#888888", position = position }
end

local P_BACKLOG = pstatus("ps-backlog", "Backlog", "backlog", 0)
local P_PLANNED = pstatus("ps-planned", "Planned", "planned", 0)
local P_DOING = pstatus("ps-doing", "In Progress", "started", 0)
local P_QA = pstatus("ps-qa", "QA", "started", 1)
local P_PAUSED = pstatus("ps-paused", "Paused", "paused", 0)
local P_DONE = pstatus("ps-done", "Completed", "completed", 0)
local P_CANCELED = pstatus("ps-canceled", "Canceled", "canceled", 0)
-- Deliberately unsorted, as an organization might return them.
local ORG_STATUSES = { P_DONE, P_QA, P_BACKLOG, P_CANCELED, P_PAUSED, P_DOING, P_PLANNED }

type ProjectOverrides = {
	name: string?,
	status: types.ProjectStatus?,
	health: string?,
	progress: number?,
	lead: types.User?,
	targetDate: string?,
	priority: number?,
	sortOrder: number?,
	teamKeys: { string }?,
	updatedAt: string?,
}

local function project(id: string, overrides: ProjectOverrides?): types.Project
	local o: ProjectOverrides = overrides or {}
	local teams: { types.ProjectTeam } = {}
	for _, key in o.teamKeys or { "ENG" } do
		table.insert(teams, { id = "t-" .. string.lower(key), key = key, name = key })
	end
	return {
		id = id,
		name = o.name or id,
		url = "https://linear.app/acme/project/" .. id,
		slugId = id,
		icon = nil,
		color = "#888888",
		summary = "",
		status = o.status or P_DOING,
		health = o.health,
		progress = o.progress or 0,
		lead = o.lead,
		startDate = nil,
		targetDate = o.targetDate,
		priority = o.priority or 0,
		sortOrder = o.sortOrder or 0,
		teams = teams,
		createdAt = "2025-01-01T00:00:00.000Z",
		updatedAt = o.updatedAt or "2025-01-01T00:00:00.000Z",
		startedAt = nil,
		completedAt = nil,
		canceledAt = nil,
	}
end

local function names(projects: { types.Project }): string
	local out: { string } = {}
	for _, p in projects do
		table.insert(out, p.name)
	end
	return table.concat(out, " ")
end

local function projectPrefs(overrides: { [string]: any }?): types.Prefs
	return prefs(overrides or {})
end

-- server filter

local activeAll: any = model.projectServerFilter(projectPrefs({ projectScope = "all", projectView = "active" }))
check(
	"project active view filters planned, started and paused statuses",
	#activeAll["and"] == 1 and table.concat(activeAll["and"][1].status.type["in"], ",") == "planned,started,paused"
)
local everything: any = model.projectServerFilter(projectPrefs({ projectScope = "all", projectView = "all" }))
check("all projects in the all view need no filter", next(everything) == nil)
local mineProjects: any = model.projectServerFilter(projectPrefs({ projectScope = "mine", projectView = "backlog" }))
local leadOrMember: any = mineProjects["and"][1]["or"]
check(
	"my projects are led by or have the viewer as a member",
	leadOrMember[1].lead.isMe.eq == true and leadOrMember[2].members.some.isMe.eq == true
)
check(
	"project backlog view filters the backlog status type",
	table.concat(mineProjects["and"][2].status.type["in"], ",") == "backlog"
)
local teamProjects: any =
	model.projectServerFilter(projectPrefs({ projectScope = "team", projectTeamId = "t-des", projectView = "all" }))
check(
	"team project scope filters on accessible teams",
	#teamProjects["and"] == 1 and teamProjects["and"][1].accessibleTeams.some.id.eq == "t-des"
)

-- visible: search, filters and board order

local apollo = project("p1", {
	name = "Apollo",
	status = P_DOING,
	health = "onTrack",
	lead = ME,
	priority = 2,
	progress = 0.5,
	targetDate = "2025-07-01",
	updatedAt = "2025-06-01T00:00:00Z",
})
local borealis = project("p2", {
	name = "Borealis",
	status = P_DOING,
	health = "atRisk",
	lead = ANA,
	priority = 1,
	progress = 0.25,
	teamKeys = { "DES" },
	targetDate = "2025-06-20",
	updatedAt = "2025-06-10T00:00:00Z",
})
local cosmos = project("p3", {
	name = "cosmos",
	status = P_PLANNED,
	priority = 0,
	sortOrder = 2,
	updatedAt = "2025-05-01T00:00:00Z",
})
local delta = project("p4", { name = "Delta", status = P_PAUSED, health = "offTrack", lead = ANA, progress = 0.75 })
local eon = project("p5", { name = "Eon", status = P_QA, priority = 2, sortOrder = 1, lead = ME, progress = 1 })
local ppool = { delta, apollo, eon, cosmos, borealis, apollo }

check(
	"visibleProjects orders by status rank, position, then priority, dropping duplicates",
	names(model.visibleProjects(ppool, projectPrefs(), "", nil)) == "cosmos Borealis Apollo Eon Delta"
)
check("project search matches the name", names(model.visibleProjects(ppool, projectPrefs(), "COSM", nil)) == "cosmos")
check(
	"project search matches the lead",
	names(model.visibleProjects(ppool, projectPrefs(), "ana", nil)) == "Borealis Delta"
)
check("project search matches team keys", names(model.visibleProjects(ppool, projectPrefs(), "des", nil)) == "Borealis")
check(
	"lead filter me",
	names(model.visibleProjects(ppool, projectPrefs({ projectLead = "me" }), "", "u-me")) == "Apollo Eon"
)
check(
	"lead filter none",
	names(model.visibleProjects(ppool, projectPrefs({ projectLead = "none" }), "", nil)) == "cosmos"
)
check(
	"lead filter by id",
	names(model.visibleProjects(ppool, projectPrefs({ projectLead = "u-ana" }), "", nil)) == "Borealis Delta"
)
check(
	"health filter",
	names(model.visibleProjects(ppool, projectPrefs({ projectHealth = "atRisk" }), "", nil)) == "Borealis"
)
check(
	"health filter none keeps projects without an update",
	names(model.visibleProjects(ppool, projectPrefs({ projectHealth = "none" }), "", nil)) == "cosmos Eon"
)

-- columns

local function columnSummary(columns: { model.ProjectColumn }): string
	local out: { string } = {}
	for _, column in columns do
		table.insert(out, `{column.title}:{#column.projects}`)
	end
	return table.concat(out, ",")
end

local activeView = projectPrefs({ projectView = "active" })
check(
	"project columns: one per status of the view, type rank then position, empty ones included",
	columnSummary(model.projectColumns(model.visibleProjects(ppool, activeView, "", nil), activeView, ORG_STATUSES))
		== "Planned:1,In Progress:2,QA:1,Paused:1"
)
local allView = projectPrefs({ projectView = "all" })
check(
	"the all view shows every status type",
	columnSummary(model.projectColumns({}, allView, ORG_STATUSES))
		== "Backlog:0,Planned:0,In Progress:0,QA:0,Paused:0,Completed:0,Canceled:0"
)
local backlogView = projectPrefs({ projectView = "backlog" })
check(
	"the backlog view shows backlog statuses only",
	columnSummary(model.projectColumns({}, backlogView, ORG_STATUSES)) == "Backlog:0"
)
local stray = project("p6", { name = "Stray", status = pstatus("ps-new", "Review", "started", 5) })
local strayColumns = model.projectColumns({ apollo, stray }, activeView, ORG_STATUSES)
check(
	"a status missing from the organization list gets its own column",
	columnSummary(strayColumns) == "Planned:0,In Progress:1,QA:0,Review:1,Paused:0"
)
check(
	"project columns carry the status id and type",
	strayColumns[2].statusId == "ps-doing" and strayColumns[2].statusType == "started"
)
local doingColumn = model.projectColumns({ apollo, borealis }, activeView, ORG_STATUSES)[2]
check("cards in a column order by priority", names(doingColumn.projects) == "Borealis Apollo")

-- table sorting

local prows = { apollo, borealis, cosmos, delta, eon }
check(
	"sort projects by name ignores case",
	names(model.sortProjects(prows, "name", true)) == "Apollo Borealis cosmos Delta Eon"
)
check(
	"sort projects by status follows the status rank",
	names(model.sortProjects(prows, "status", true)) == "cosmos Apollo Borealis Eon Delta"
)
check(
	"sort by health puts off track first and no update last",
	names(model.sortProjects(prows, "health", true)) == "Delta Borealis Apollo cosmos Eon"
)
check(
	"sort by lead puts projects without a lead last",
	names(model.sortProjects(prows, "lead", true)) == "Borealis Delta Apollo Eon cosmos"
)
check(
	"sort by target date puts projects without one last",
	names(model.sortProjects(prows, "target", true)) == "Borealis Apollo cosmos Delta Eon"
)
check(
	"sort by progress descending",
	names(model.sortProjects(prows, "progress", false)) == "Eon Delta Apollo Borealis cosmos"
)
check(
	"sort by updated is newest first when descending",
	names(model.sortProjects({ apollo, borealis, cosmos }, "updated", false)) == "Borealis Apollo cosmos"
)
check("sorting projects does not mutate its input", names(prows) == "Apollo Borealis cosmos Delta Eon")

-- labels

local june = model.epoch("2025-06-15T12:00:00Z") :: number
check("shortDate in the current year", model.shortDate("2025-07-01", june) == "Jul 1")
check("shortDate in another year", model.shortDate("2026-01-09", june) == "Jan 9, 2026")
check("shortDate of garbage is empty", model.shortDate("soon", june) == "")
check(
	"resolvedDate at Linear's precisions",
	model.resolvedDate("2025-09-30", "month", june) == "Sep 2025"
		and model.resolvedDate("2025-09-30", "quarter", june) == "Q3 2025"
		and model.resolvedDate("2025-10-01", "quarter", june) == "Q4 2025"
		and model.resolvedDate("2025-06-30", "halfYear", june) == "H1 2025"
		and model.resolvedDate("2025-07-01", "halfYear", june) == "H2 2025"
		and model.resolvedDate("2026-12-31", "year", june) == "2026"
)
check(
	"resolvedDate of an exact date is shortDate",
	model.resolvedDate("2025-07-01", nil, june) == "Jul 1"
		and model.resolvedDate("2026-01-09", "day", june) == "Jan 9, 2026"
)
check(
	"progressLabel rounds down and clamps",
	model.progressLabel(0.629) == "62%" and model.progressLabel(1) == "100%" and model.progressLabel(1.5) == "100%"
)
check("progressLabel of exact tenths", model.progressLabel(0.7) == "70%" and model.progressLabel(0.29) == "29%")
check("healthLabel", model.healthLabel("atRisk") == "At risk" and model.healthLabel(nil) == "No update")
check(
	"projectStatusRank follows PROJECT_STATUS_TYPES",
	model.projectStatusRank("backlog") == 1 and model.projectStatusRank("paused") == 4
)

-- project page

local function milestone(id: string, name: string, sortOrder: number, targetDate: string?): types.ProjectMilestone
	return { id = id, name = name, status = "unstarted", progress = 0, targetDate = targetDate, sortOrder = sortOrder }
end

local function milestoneNames(list: { types.ProjectMilestone }): string
	local out: { string } = {}
	for _, m in list do
		table.insert(out, m.name)
	end
	return table.concat(out, " ")
end

local unsortedMilestones = {
	milestone("m-launch", "Launch", 3, "2025-09-01"),
	milestone("m-alpha", "Alpha", 1, "2025-08-01"),
	milestone("m-undated", "Undated", 2, nil),
	milestone("m-beta", "Beta", 2, "2025-08-15"),
	milestone("m-zulu", "zulu", 4, "2025-07-01"),
	milestone("m-echo", "echo", 4, "2025-07-01"),
}
check(
	"milestones follow sortOrder, then target date (none last), then name",
	milestoneNames(model.sortMilestones(unsortedMilestones)) == "Alpha Beta Undated Launch echo zulu"
)
check("sorting milestones does not mutate its input", unsortedMilestones[1].name == "Launch")
local foundBeta = model.milestoneById(unsortedMilestones, "m-beta")
check(
	"milestoneById finds a milestone of the list; nil for an unknown or nil id",
	foundBeta ~= nil
		and foundBeta.name == "Beta"
		and model.milestoneById(unsortedMilestones, "m-gone") == nil
		and model.milestoneById(unsortedMilestones, nil) == nil
		and model.milestoneById({}, "m-beta") == nil
)
check(
	"milestone status labels",
	model.milestoneStatusLabel("done") == "Done"
		and model.milestoneStatusLabel("next") == "Next"
		and model.milestoneStatusLabel("overdue") == "Overdue"
		and model.milestoneStatusLabel("unstarted") == "Not started"
		and model.milestoneStatusLabel("someday") == "Not started"
)
check(
	"namesLabel caps the list with a count",
	model.namesLabel({ "ada", "grace", "linus" }, 2) == "ada, grace +1"
		and model.namesLabel({ "ada", "grace" }, 2) == "ada, grace"
		and model.namesLabel({}, 3) == ""
)
check(
	"projectTab accepts known tabs only",
	model.projectTab("overview") == "overview"
		and model.projectTab("activity") == "activity"
		and model.projectTab("issues") == "issues"
		and model.projectTab("gantt") == nil
		and model.projectTab(nil) == nil
)
check(
	"PROJECT_TABS: Overview, Activity, then Issues",
	model.PROJECT_TABS[1].id == "overview"
		and model.PROJECT_TABS[2].id == "activity"
		and model.PROJECT_TABS[3].id == "issues"
		and #model.PROJECT_TABS == 3
)
local tabCount = #model.PROJECT_TABS
check(
	"stepProjectTab wraps around the tab list",
	model.stepProjectTab("overview", 1) == "activity"
		and model.stepProjectTab("activity", 1) == "issues"
		and model.stepProjectTab("issues", 1) == "overview"
		and model.stepProjectTab("overview", -1) == "issues"
		and model.stepProjectTab("overview", tabCount) == "overview"
)

-- the project page's Issues tab

local projectActive: any = model.projectIssueFilter("p-1", "active", nil)
check(
	"projectIssueFilter: the project AND the view's state types",
	#projectActive["and"] == 2
		and projectActive["and"][1].project.id.eq == "p-1"
		and table.concat(projectActive["and"][2].state.type["in"], ",") == "triage,unstarted,started"
)
local projectAll: any = model.projectIssueFilter("p-1", "all", nil)
check(
	"projectIssueFilter: the All view keeps open and recently closed issues",
	projectAll["and"][2]["or"][2].completedAt.gt == "-P14D"
)
local projectMilestone: any = model.projectIssueFilter("p-1", "backlog", "m-1")
check(
	"projectIssueFilter: a milestone narrows the project before the view",
	#projectMilestone["and"] == 3
		and projectMilestone["and"][2].projectMilestone.id.eq == "m-1"
		and projectMilestone["and"][3].state.type["in"][1] == "backlog"
)

local function titles(columns: { model.Column }): string
	local out: { string } = {}
	for _, column in columns do
		table.insert(out, `{column.title}:{#column.issues}`)
	end
	return table.concat(out, ",")
end
local designDoing = issue("d1", { teamKey = "DES", number = 4, state = state("s-des-doing", "Doing", "started", 3) })
check(
	"typeColumns: one column per state type of the view across teams, empty ones included",
	titles(model.typeColumns({ inTodo, designDoing, urgent, inReview }, "active")) == "Triage:0,Todo:1,In Progress:3"
)
check(
	"typeColumns: the All view folds duplicate into canceled",
	titles(model.typeColumns({ issue("x1", { state = DUPLICATE }) }, "all"))
		== "Triage:0,Backlog:0,Todo:0,In Progress:0,Done:0,Canceled:1"
)

local function stateId(target: types.WorkflowState?): string
	return if target ~= nil then target.id else "nil"
end
check(
	"adjacentTypeState moves to the next type's first state",
	stateId(model.adjacentTypeState(team, issue("m1", { state = TODO }), 1, "active")) == "s-doing"
		and stateId(model.adjacentTypeState(team, issue("m2", { state = REVIEW }), -1, "active")) == "s-todo"
)
check(
	"adjacentTypeState stops at the view's edges and skips types the team lacks",
	model.adjacentTypeState(team, issue("m3", { state = REVIEW }), 1, "active") == nil
		and model.adjacentTypeState(team, issue("m4", { state = TODO }), -1, "active") == nil
)
check(
	"adjacentTypeState: duplicate sits in the canceled column",
	stateId(model.adjacentTypeState(team, issue("m5", { state = DUPLICATE }), -1, "all")) == "s-done"
		and model.adjacentTypeState(team, issue("m6", { state = CANCELED }), 1, "all") == nil
)
check(
	"adjacentTypeState: an issue outside the view steps through every type",
	stateId(model.adjacentTypeState(team, issue("m7", { state = BACKLOG }), 1, "active")) == "s-todo"
)
local lean: types.Team = table.clone(team)
lean.states = { BACKLOG, TODO, DONE }
check(
	"adjacentTypeState uses the issue's own team: a team without a started state goes straight to done",
	stateId(model.adjacentTypeState(lean, issue("m8", { state = TODO }), 1, "all")) == "s-done"
)

local design: types.Team = table.clone(team)
design.id = "t-des"
local ops: types.Team = table.clone(team)
ops.id = "t-ops"
local owners = model.issueTeams({ inTodo, designDoing, urgent }, { design, ops, team })
check(
	"issueTeams: the teams owning the issues, in team-list order",
	#owners == 2 and owners[1].id == "t-des" and owners[2].id == "t-eng"
)

local tabState = { prefs = { mode = "projects" }, projectPage = { tab = "issues", issues = { items = {} } } }
check("issuesTab: the page's Issues tab on screen", model.issuesTab(tabState :: any) == tabState.projectPage.issues)
tabState.projectPage.tab = "overview"
check("issuesTab: nil on another tab", model.issuesTab(tabState :: any) == nil)
tabState.projectPage.tab = "issues"
tabState.prefs.mode = "issues"
check("issuesTab: nil in issues mode", model.issuesTab(tabState :: any) == nil)

check(
	"steppedId clamps at the ends and starts at the first id",
	model.steppedId({ "a", "b", "c" }, "b", 1) == "c"
		and model.steppedId({ "a", "b", "c" }, "c", 1) == "c"
		and model.steppedId({ "a", "b", "c" }, "a", -1) == "a"
		and model.steppedId({ "a", "b" }, "gone", 1) == "a"
		and model.steppedId({}, nil, 1) == nil
)
check(
	"adjacentColumnId skips empty columns and stops at the edge",
	model.adjacentColumnId({ { "a" }, {}, { "c", "d" } }, "a", 1) == "c"
		and model.adjacentColumnId({ { "a" }, {}, { "c", "d" } }, "d", -1) == "a"
		and model.adjacentColumnId({ { "a" }, { "b" } }, "b", 1) == nil
		and model.adjacentColumnId({ {}, { "b" } }, nil, -1) == "b"
)
local sortKey, sortAsc = model.nextSort("updated", false, "priority")
local againKey, againAsc = model.nextSort("priority", true, "priority")
local newestKey, newestAsc = model.nextSort("title", true, "updated")
check(
	"nextSort: a new key ascends (updated descends), the same key flips",
	sortKey == "priority"
		and sortAsc
		and againKey == "priority"
		and not againAsc
		and newestKey == "updated"
		and not newestAsc
)

-- project activity

local NOW = model.epoch("2026-11-22T12:00:00Z") :: number
local function msAgo(seconds: number): number
	return (NOW - seconds) * 1000
end
local NAMES = model.activityNames({ user("u-ada", "ada"), user("u-grace", "grace"), user("u-ada", "shadow") }, {
	{ id = "t-eng", name = "Engineering" },
	{ id = "t-des", name = "Design" },
}, { { id = "m-alpha", name = "Alpha" }, { id = "m-beta", name = "Beta" } })
check("activityNames keeps the first name per id", NAMES.users["u-ada"] == "ada" and NAMES.teams["t-des"] == "Design")

local function line(entry: any): string?
	local event = model.historyEvent(entry, NAMES, NOW)
	if event == nil then
		return nil
	end
	return if event.actor ~= nil then `{event.actor} {event.text}` else event.text
end

local AT = msAgo(3600)
check("status change", line({
	type = "status",
	at = AT,
	actorId = "u-ada",
	fromStatus = { id = "s1", name = "Planned", type = "planned" },
	toStatus = { id = "s2", name = "In Progress", type = "started" },
}) == "ada changed status from Planned to In Progress")
check(
	"start date",
	line({ type = "startDate", at = AT, actorId = "u-grace", to = "2026-11-30" })
		== "grace set the start date to Nov 30"
)
check(
	"rename",
	line({ type = "name", at = AT, actorId = "u-ada", from = "Desktop client", to = "Desktop app" })
		== "ada renamed the project from Desktop client to Desktop app"
)
check("icon", line({ type = "icon", at = AT, actorId = "u-ada", to = "Rocket" }) == "ada changed the icon")
check(
	"content with several actors",
	line({ type = "content", at = AT, actorIds = { "u-ada", "u-grace" } }) == "ada and grace updated the description"
)
check("description by an integration", line({
	type = "description",
	at = AT,
	actorId = "u-bot",
	source = { type = "oauthClient", displayName = "Zapier" },
}) == "Zapier updated the summary")
check(
	"an unknown actor reads Someone",
	line({ type = "description", at = AT, actorId = "u-gone", source = { type = "apiKey" } })
		== "Someone updated the summary"
)
check(
	"lead team",
	line({ type = "leadTeamId", at = AT, actorId = "u-ada", from = "t-eng", to = "t-des" })
			== "ada changed the lead team from Engineering to Design"
		and line({ type = "leadTeamId", at = AT, actorId = "u-ada", from = "t-x", to = "t-y" })
			== "ada changed the lead team"
)
check(
	"teams added and removed",
	line({ type = "teams", at = AT, actorId = "u-ada", added = { "t-des" }, removed = {} }) == "ada added team Design"
		and line({ type = "teams", at = AT, actorId = "u-ada", added = {}, removed = { "t-eng", "t-x" } }) == "ada removed teams Engineering and 1 other"
		and line({ type = "teams", at = AT, actorId = "u-ada", added = { "t-x" }, removed = {} })
			== "ada added a team"
)
check("milestones added", line({
	type = "milestones",
	at = AT,
	actorId = "u-grace",
	added = { { id = "m1", name = "Alpha" }, { id = "m2", name = "Beta" } },
	removed = { { id = "m3", name = "Gamma" } },
}) == "grace added milestones Alpha and Beta and removed milestone Gamma")
local completion = model.historyEvent(
	{ type = "milestone_completion", at = AT, milestone = { id = "m1", name = "Alpha" } },
	NAMES,
	NOW
)
check(
	"milestone completion has no actor",
	completion ~= nil and completion.actor == nil and completion.text == "Milestone Alpha completed"
)
check("event time is epoch seconds", completion ~= nil and completion.time == NOW - 3600)
-- Linear sends milestone references with an empty name: the project's milestones name them by id.
check(
	"milestone references resolve by id",
	line({ type = "milestone_completion", at = AT, milestone = { id = "m-beta", name = "" } })
			== "Milestone Beta completed"
		and line({
				type = "milestones",
				at = AT,
				actorId = "u-grace",
				added = { { id = "m-alpha", name = "" }, { id = "m-gone", name = "" } },
				removed = {},
			})
			== "grace added milestones Alpha and 1 other"
)
check(
	"unknown milestones read generically",
	line({ type = "milestone_completion", at = AT, milestone = { id = "m-gone", name = "" } })
			== "A milestone was completed"
		and line({
				type = "milestones",
				at = AT,
				actorId = "u-ada",
				added = { { id = "m-gone", name = "" } },
				removed = {},
			})
			== "ada added a milestone"
)

check("unknown kinds are skipped", line({ type = "labels", at = AT, actorId = "u-ada", added = { "l1" } }) == nil)
check("entries without a numeric at are skipped", line({ type = "icon", at = "yesterday", actorId = "u-ada" }) == nil)
check("entries without a type are skipped", line({ at = AT, actorId = "u-ada" }) == nil)
check("non-table entries are skipped", line("status") == nil and line(nil) == nil)
check(
	"malformed known kinds are skipped",
	line({ type = "status", at = AT, actorId = "u-ada", fromStatus = { name = "Planned" } }) == nil
		and line({ type = "startDate", at = AT, actorId = "u-ada", to = "soon" }) == nil
		and line({ type = "teams", at = AT, actorId = "u-ada", added = { 42 } }) == nil
		and line({ type = "teams", at = AT, actorId = "u-ada", added = "t-eng" }) == nil
		and line({ type = "milestones", at = AT, actorId = "u-ada", added = { "m1" } }) == nil
		and line({ type = "milestones", at = AT, actorId = "u-ada", added = {}, removed = {} }) == nil
		and line({ type = "milestone_completion", at = AT }) == nil
		and line({ type = "leadTeamId", at = AT, actorId = "u-ada", from = {} }) == nil
		and line({ type = "leadTeamId", at = AT, actorId = "u-ada", from = "t-eng", to = 42 }) == nil
		and line({ type = "leadTeamId", at = AT, actorId = "u-ada" }) == nil
)
check(
	"entries with an at outside the host's dates are skipped",
	line({ type = "icon", at = 1e30, actorId = "u-ada" }) == nil
		and line({ type = "icon", at = 0 / 0, actorId = "u-ada" }) == nil
)

local function iso(secondsAgo: number): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - secondsAgo) :: string
end

local function update(id: string, secondsAgo: number): types.ProjectUpdate
	return {
		id = id,
		body = "",
		health = "onTrack",
		createdAt = iso(secondsAgo),
		editedAt = nil,
		commentCount = 0,
		url = "",
		user = nil,
		comments = {},
	}
end

local function record(id: string, updatedAgo: number, entries: { any }): types.ProjectHistoryRecord
	return { id = id, createdAt = iso(updatedAgo + 600), updatedAt = iso(updatedAgo), entries = entries }
end

local function icon(secondsAgo: number): any
	return { type = "icon", at = msAgo(secondsAgo), actorId = "u-ada", to = "Rocket" }
end

local function itemIds(timeline: model.ActivityTimeline): string
	local out: { string } = {}
	for _, item in timeline.items do
		table.insert(out, item.id)
	end
	return table.concat(out, " ")
end

local function source<T>(items: { T }, cursor: string?): types.ActivitySource<T>
	return { items = items, cursor = cursor, hasMore = cursor ~= nil }
end

local complete: types.ProjectActivity = {
	updates = source({ update("u2", 100), update("u1", 500) }, nil),
	history = source({
		record("h2", 200, { icon(300), { type = "future", at = msAgo(250) }, icon(200) }),
		record("h1", 400, { icon(400), "garbage" }),
	}, nil),
}
local whole = model.activityTimeline(complete, NAMES, NOW)
check("timeline merges updates and events newest first", itemIds(whole) == "u2 h2:3 h2:1 h1:1 u1")
check("timeline without more pages", not whole.more and model.activityCursors(complete) == nil)

local tie = model.activityTimeline({
	updates = source({ update("a", 100) }, nil),
	history = source({ record("z", 100, { icon(100) }) }, nil),
}, NAMES, NOW)
check("equal times list events before updates", itemIds(tie) == "z:1 a")
local badTime = model.activityTimeline({
	updates = source({}, nil),
	history = source({ record("h9", 100, { { type = "icon", at = 1e30, actorId = "u-ada" }, icon(100) }) }, nil),
}, NAMES, NOW)
check("an entry with an unusable time leaves its neighbours", itemIds(badTime) == "h9:2")

-- Updates have another page below u1 (500 s ago): older history events wait for it.
local partial: types.ProjectActivity = {
	updates = source({ update("u2", 100), update("u1", 500) }, "c-u"),
	history = source({ record("h1", 50, { icon(50), icon(800) }) }, nil),
}
local held = model.activityTimeline(partial, NAMES, NOW)
check("items older than a paged source's oldest wait for Load more", itemIds(held) == "h1:1 u2 u1" and held.more)
local cursors = model.activityCursors(partial)
check(
	"activityCursors names only sources with more",
	cursors ~= nil and cursors.updates == "c-u" and cursors.history == nil
)

-- History paged by updatedAt: the oldest loaded record's updatedAt is the floor.
local historyPaged = model.activityTimeline({
	updates = source({ update("u1", 1000) }, nil),
	history = source({ record("h1", 300, { icon(900), icon(300) }) }, "c-h"),
}, NAMES, NOW)
check("a paged history holds back events older than its oldest record", itemIds(historyPaged) == "h1:2")

-- Equal times at a page boundary: the next page lists below everything shown, in its source and across sources.
local updatesBoundary: types.ProjectActivity = {
	updates = source({ update("z", 100) }, "c-u"),
	history = source({ record("y", 100, { icon(100) }) }, nil),
}
local updatesBoundaryMore = model.activityAppended(updatesBoundary, {
	updates = source({ update("a", 100) }, nil),
	history = source({}, nil),
}, { updates = "c-u", history = nil })
check(
	"Load more lists updates of the boundary time below the shown items",
	itemIds(model.activityTimeline(updatesBoundary, NAMES, NOW)) == "y:1 z"
		and itemIds(model.activityTimeline(updatesBoundaryMore, NAMES, NOW)) == "y:1 z a"
)
local historyBoundary: types.ProjectActivity = {
	updates = source({ update("a", 100) }, nil),
	history = source({ record("h2", 100, { icon(100) }) }, "c-h"),
}
local historyBoundaryMore = model.activityAppended(historyBoundary, {
	updates = source({}, nil),
	history = source({ record("h1", 100, { icon(100) }) }, nil),
}, { updates = nil, history = "c-h" })
check(
	"updates at a paged history's oldest time wait for its next page",
	itemIds(model.activityTimeline(historyBoundary, NAMES, NOW)) == "h2:1"
		and itemIds(model.activityTimeline(historyBoundaryMore, NAMES, NOW)) == "h2:1 h1:1 a"
)

local appended = model.activityAppended(partial, {
	updates = source({ update("u1", 500), update("u0", 900) }, nil),
	history = source({}, nil),
}, { updates = "c-u", history = nil })
check(
	"Load more appends new items once and takes the page's cursor",
	#appended.updates.items == 3
		and appended.updates.items[3].id == "u0"
		and not appended.updates.hasMore
		and appended.history == partial.history
)
check("after Load more everything shows", itemIds(model.activityTimeline(appended, NAMES, NOW)) == "h1:1 u2 u1 h1:2 u0")

local loadedMore: types.ProjectActivity = {
	updates = source({ update("u3", 100), update("u2", 200), update("u1", 300) }, "c-old"),
	history = source({ record("h1", 100, {}) }, nil),
}
local reloaded = model.activityReloaded(loadedMore, {
	updates = source({ update("u4", 10), update("u3", 100) }, "c-fresh"),
	history = source({ record("h1", 100, { icon(100) }) }, nil),
})
local reloadedIds: { string } = {}
for _, item in reloaded.updates.items do
	table.insert(reloadedIds, item.id)
end
check(
	"a reload keeps the older pages and their cursor",
	table.concat(reloadedIds, " ") == "u4 u3 u2 u1" and reloaded.updates.cursor == "c-old"
)
check("a reload replaces a source that fits one page", #reloaded.history.items[1].entries == 1)
local first = model.activityReloaded(nil, complete)
check("the first load is the fresh data", first == complete)
local function sourceIds<T>(items: { T }, idOf: (T) -> string): string
	local out: { string } = {}
	for _, item in items do
		table.insert(out, idOf(item))
	end
	return table.concat(out, " ")
end
local function updateIds(activity: types.ProjectActivity): string
	return sourceIds(activity.updates.items, function(item: types.ProjectUpdate): string
		return item.id
	end)
end
-- A fresh page that shares no item with the loaded ones may leave a gap below it: it restarts the source.
local gapped = model.activityReloaded(complete, {
	updates = source({ update("u9", 5), update("u8", 10) }, "c-new"),
	history = complete.history,
})
check(
	"a reload with a gap below its page restarts from the fresh page",
	updateIds(gapped) == "u9 u8" and gapped.updates.cursor == "c-new" and gapped.updates.hasMore
)
local grown = model.activityReloaded(complete, {
	updates = source({ update("u9", 5), update("u2", 100) }, "c-new"),
	history = complete.history,
})
check("a reload reaching a complete list stays complete", updateIds(grown) == "u9 u2 u1" and not grown.updates.hasMore)
local tied = model.activityReloaded({
	updates = source({ update("b", 100), update("z", 100), update("a", 200) }, nil),
	history = complete.history,
}, {
	updates = source({ update("new", 50), update("b", 100) }, "c-new"),
	history = complete.history,
})
check("a reload keeps loaded items tied with its oldest", updateIds(tied) == "new b z a" and not tied.updates.hasMore)
-- A history record updated since moved up: its old place proves nothing; an unchanged one anchors the merge.
local function historyIds(activity: types.ProjectActivity): string
	return sourceIds(activity.history.items, function(item: types.ProjectHistoryRecord): string
		return item.id
	end)
end
local fourRecords: types.ProjectActivity = {
	updates = complete.updates,
	history = source(
		{ record("h4", 300, {}), record("h3", 400, {}), record("h2", 500, {}), record("h1", 600, {}) },
		nil
	),
}
local movedOnly = model.activityReloaded(fourRecords, {
	updates = complete.updates,
	history = source({ record("h1", 10, {}), record("h3", 20, {}) }, "c-h"),
})
local anchored = model.activityReloaded(fourRecords, {
	updates = complete.updates,
	history = source({ record("h1", 10, {}), record("h4", 300, {}) }, "c-h"),
})
check(
	"a reload anchors on an unchanged record only",
	historyIds(movedOnly) == "h1 h3"
		and movedOnly.history.cursor == "c-h"
		and historyIds(anchored) == "h1 h4 h3 h2"
		and not anchored.history.hasMore
)
local caughtUp = model.activityReloaded({
	updates = source({ update("u2", 100) }, "c-old"),
	history = complete.history,
}, {
	updates = source({ update("u3", 50), update("u2", 100) }, "c-fresh"),
	history = complete.history,
})
check(
	"a reload that covers every loaded item takes the fresh cursor",
	#caughtUp.updates.items == 2 and caughtUp.updates.cursor == "c-fresh"
)

check(
	"relativeSince matches relativeTime",
	model.relativeSince(NOW - 7200, NOW) == "2h" and model.relativeSince(NOW - 3 * 86400, NOW) == "3d"
)
check("absoluteTime format", string.match(model.absoluteTime(NOW), "^%a%a%a %d+, %d%d%d%d, %d%d:%d%d$") ~= nil)

if failures > 0 then
	error(`{failures} model test(s) failed`)
end
print("model tests passed")
