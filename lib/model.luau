--!strict
-- Pure board logic: grouping, filtering, ordering, server filters, blocked state, dates and form diffs.
-- No `tern.*` access: this module is unit-tested with the stand-alone `luau` CLI.

local types = require("./types")

type Issue = types.Issue
type IssueRef = types.IssueRef
type Prefs = types.Prefs
type Project = types.Project
type ProjectStatus = types.ProjectStatus
type ProjectMilestone = types.ProjectMilestone
type ProjectTab = types.ProjectTab
type Team = types.Team
type WorkflowState = types.WorkflowState
type Form = types.Form

export type Column = {
	id: string,
	title: string,
	stateType: string,
	stateId: string?,
	color: string?,
	issues: { Issue },
}

-- One board column of projects mode: an organization project status.
export type ProjectColumn = {
	id: string,
	title: string,
	statusType: string,
	statusId: string,
	color: string,
	projects: { Project },
}

local model = {}

-- ─── State types and priorities ─────────────────────────────────────────────

local STATE_TYPES: { string } =
	table.freeze({ "triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate" })
model.STATE_TYPES = STATE_TYPES

local TYPE_TITLES: { [string]: string } = {
	triage = "Triage",
	backlog = "Backlog",
	unstarted = "Todo",
	started = "In Progress",
	completed = "Done",
	canceled = "Canceled",
	duplicate = "Duplicate",
}

local PRIORITIES: { { value: number, label: string } } = {
	{ value = 1, label = "Urgent" },
	{ value = 2, label = "High" },
	{ value = 3, label = "Medium" },
	{ value = 4, label = "Low" },
	{ value = 0, label = "No priority" },
}
model.TYPE_TITLES = TYPE_TITLES
model.PRIORITIES = PRIORITIES

local VIEW_TYPES: { [string]: { string } } = {
	active = table.freeze({ "triage", "unstarted", "started" }),
	backlog = table.freeze({ "backlog" }),
	all = STATE_TYPES,
}

local CLOSED_TYPES: { string } = { "completed", "canceled", "duplicate" }

function model.typeRank(t: string): number
	local rank = table.find(model.STATE_TYPES, t)
	return rank or #model.STATE_TYPES + 1
end

function model.isClosedType(t: string): boolean
	return table.find(CLOSED_TYPES, t) ~= nil
end

function model.viewTypes(view: string): { string }
	return VIEW_TYPES[view] or VIEW_TYPES.active
end

function model.priorityLabel(p: number): string
	for _, entry in model.PRIORITIES do
		if entry.value == p then
			return entry.label
		end
	end
	return "No priority"
end

-- ─── Relations ──────────────────────────────────────────────────────────────

-- Unresolved issues that block `issue` (incoming "blocks" whose other side is not closed).
function model.blockers(issue: Issue): { IssueRef }
	local out: { IssueRef } = {}
	for _, relation in issue.relations do
		if
			relation.type == "blocks"
			and relation.direction == "incoming"
			and not model.isClosedType(relation.other.stateType)
		then
			table.insert(out, relation.other)
		end
	end
	return out
end

function model.isBlocked(issue: Issue): boolean
	return #model.blockers(issue) > 0
end

-- ─── Identifiers ────────────────────────────────────────────────────────────

-- "eng-12" → "ENG", 12
function model.parseIdentifier(s: string): (string?, number?)
	local key, number = string.match(s, "^%s*(%a[%w]*)%-(%d+)%s*$")
	if key == nil or number == nil then
		return nil, nil
	end
	return string.upper(key), tonumber(number)
end

-- ─── Server filter ──────────────────────────────────────────────────────────

local function stateTypeFilter(comparator: string, stateTypes: { string }): any
	return { state = { type = { [comparator] = stateTypes } } }
end

local function viewFilter(view: string): any
	if view == "all" then
		return {
			["or"] = {
				stateTypeFilter("nin", CLOSED_TYPES),
				{ completedAt = { gt = "-P14D" } },
				{ canceledAt = { gt = "-P14D" } },
			},
		}
	end
	return stateTypeFilter("in", model.viewTypes(view))
end

-- Linear IssueFilter as plain tables; non-empty arrays encode as JSON arrays.
function model.serverFilter(prefs: Prefs): any
	local parts: { any } = {}
	if prefs.scope == "mine" then
		table.insert(parts, { assignee = { isMe = { eq = true } } })
	elseif prefs.teamId ~= nil then
		table.insert(parts, { team = { id = { eq = prefs.teamId } } })
	end
	table.insert(parts, viewFilter(prefs.view))
	return { ["and"] = parts }
end

-- ─── Ordering ───────────────────────────────────────────────────────────────

local NO_PRIORITY_RANK = 5

local function priorityRank(p: number): number
	return if p == 0 then NO_PRIORITY_RANK else p
end

local function compare(a: number, b: number): number
	if a < b then
		return -1
	end
	return if a > b then 1 else 0
end

local function compareText(a: string, b: string): number
	local left, right = string.lower(a), string.lower(b)
	if left < right then
		return -1
	end
	return if left > right then 1 else 0
end

local function compareIdentifier(a: Issue, b: Issue): number
	local byTeam = compareText(a.teamKey, b.teamKey)
	if byTeam ~= 0 then
		return byTeam
	end
	return compare(a.number, b.number)
end

local function compareState(a: Issue, b: Issue): number
	local byType = compare(model.typeRank(a.state.type), model.typeRank(b.state.type))
	if byType ~= 0 then
		return byType
	end
	local byPosition = compare(a.state.position, b.state.position)
	return if byPosition ~= 0 then byPosition else compareText(a.state.name, b.state.name)
end

-- Priority (1..4, then none), then manual sort order, then identifier.
local function compareCard(a: Issue, b: Issue): number
	local byPriority = compare(priorityRank(a.priority), priorityRank(b.priority))
	if byPriority ~= 0 then
		return byPriority
	end
	local bySortOrder = compare(a.sortOrder, b.sortOrder)
	return if bySortOrder ~= 0 then bySortOrder else compareIdentifier(a, b)
end

local function compareBoard(a: Issue, b: Issue): number
	local byState = compareState(a, b)
	return if byState ~= 0 then byState else compareCard(a, b)
end

local function lessWith(compareIssues: (Issue, Issue) -> number): (Issue, Issue) -> boolean
	return function(a: Issue, b: Issue): boolean
		local c = compareIssues(a, b)
		if c ~= 0 then
			return c < 0
		end
		return a.id < b.id
	end
end

-- ─── Dates ──────────────────────────────────────────────────────────────────

local SECONDS_PER_DAY = 86400
local MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's days_from_civil).
local function daysFromCivil(year: number, month: number, day: number): number
	local y = if month <= 2 then year - 1 else year
	local era = y // 400
	local yearOfEra = y - era * 400
	local monthIndex = (month + 9) % 12
	local dayOfYear = (153 * monthIndex + 2) // 5 + day - 1
	local dayOfEra = yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
	return era * 146097 + dayOfEra - 719468
end

-- Inverse of daysFromCivil: (year, month, day).
local function civilFromDays(days: number): (number, number, number)
	local z = days + 719468
	local era = z // 146097
	local dayOfEra = z - era * 146097
	local yearOfEra = (dayOfEra - dayOfEra // 1460 + dayOfEra // 36524 - dayOfEra // 146096) // 365
	local dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra // 4 - yearOfEra // 100)
	local monthIndex = (5 * dayOfYear + 2) // 153
	local day = dayOfYear - (153 * monthIndex + 2) // 5 + 1
	local month = if monthIndex < 10 then monthIndex + 3 else monthIndex - 9
	local year = yearOfEra + era * 400
	return (if month <= 2 then year + 1 else year), month, day
end

-- Seconds east of UTC for "Z", "", "+HH:MM", "-HHMM"; nil when malformed.
local function parseOffset(s: string): number?
	if s == "" or s == "Z" or s == "z" then
		return 0
	end
	local sign, hours, minutes = string.match(s, "^([+-])(%d%d):?(%d%d)$")
	if sign == nil or hours == nil or minutes == nil then
		return nil
	end
	local seconds = (tonumber(hours) :: number) * 3600 + (tonumber(minutes) :: number) * 60
	return if sign == "-" then -seconds else seconds
end

local function validDate(month: number, day: number): boolean
	return month >= 1 and month <= 12 and day >= 1 and day <= 31
end

-- "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS(.fff)?(Z|±HH:MM)" → UTC epoch seconds.
function model.epoch(iso: string): number?
	local y, mo, d = string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if y ~= nil and mo ~= nil and d ~= nil then
		local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
		if not validDate(month, day) then
			return nil
		end
		return daysFromCivil(year, month, day) * SECONDS_PER_DAY
	end

	local ty, tmo, td, hh, mm, ss, fraction, zone =
		string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
	if
		ty == nil
		or tmo == nil
		or td == nil
		or hh == nil
		or mm == nil
		or ss == nil
		or fraction == nil
		or zone == nil
	then
		return nil
	end
	local offset = parseOffset(zone)
	local year, month, day = tonumber(ty) :: number, tonumber(tmo) :: number, tonumber(td) :: number
	local hour, minute, second = tonumber(hh) :: number, tonumber(mm) :: number, tonumber(ss) :: number
	local malformedFraction = fraction ~= "" and string.sub(fraction, 1, 1) ~= "."
	if offset == nil or malformedFraction or not validDate(month, day) or hour > 23 or minute > 59 or second > 60 then
		return nil
	end
	local fractional = if #fraction > 1 then tonumber("0" .. fraction) or 0 else 0
	local localSeconds = daysFromCivil(year, month, day) * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second
	return localSeconds - offset + fractional
end

-- "now", "5m", "3h", "2d", else "Mar 4" (with the year when it is not the current one).
function model.relativeTime(iso: string, now: number): string
	local at = model.epoch(iso)
	if at == nil then
		return ""
	end
	return model.relativeSince(at, now)
end

-- model.relativeTime of an epoch second.
function model.relativeSince(at: number, now: number): string
	local elapsed = now - at
	if elapsed < 60 then
		return "now"
	elseif elapsed < 3600 then
		return `{elapsed // 60}m`
	elseif elapsed < SECONDS_PER_DAY then
		return `{elapsed // 3600}h`
	end
	local days = elapsed // SECONDS_PER_DAY
	if days <= 30 then
		return `{days}d`
	end
	local year, month, day = civilFromDays(at // SECONDS_PER_DAY)
	local currentYear = civilFromDays(now // SECONDS_PER_DAY)
	local label = `{MONTH_NAMES[month]} {day}`
	return if year == currentYear then label else `{label}, {year}`
end

-- ─── Filtering ──────────────────────────────────────────────────────────────

local function searchHaystack(issue: Issue): string
	local parts: { string } = { issue.identifier, issue.title }
	for _, label in issue.labels do
		table.insert(parts, label.name)
	end
	local assignee = issue.assignee
	if assignee ~= nil then
		table.insert(parts, assignee.name)
		table.insert(parts, assignee.displayName)
	end
	return string.lower(table.concat(parts, "\n"))
end

local function matchesQuery(issue: Issue, needle: string, key: string?, number: number?): boolean
	if key ~= nil and number ~= nil and string.upper(issue.teamKey) == key and issue.number == number then
		return true
	end
	return string.find(searchHaystack(issue), needle, 1, true) ~= nil
end

local function matchesAssignee(issue: Issue, wanted: string, viewerId: string?): boolean
	local assignee = issue.assignee
	if wanted == "none" then
		return assignee == nil
	end
	local id = if wanted == "me" then viewerId else wanted
	return assignee ~= nil and id ~= nil and assignee.id == id
end

local function hasLabel(issue: Issue, labelId: string): boolean
	for _, label in issue.labels do
		if label.id == labelId then
			return true
		end
	end
	return false
end

function model.visible(issues: { Issue }, prefs: Prefs, query: string, viewerId: string?): { Issue }
	local needle = string.lower(string.match(query, "^%s*(.-)%s*$") :: string)
	local key, number = model.parseIdentifier(needle)
	local seen: { [string]: boolean } = {}
	local out: { Issue } = {}
	for _, issue in issues do
		local keep = not seen[issue.id]
			and (needle == "" or matchesQuery(issue, needle, key, number))
			and (prefs.priority == nil or issue.priority == prefs.priority)
			and (prefs.assignee == nil or matchesAssignee(issue, prefs.assignee, viewerId))
			and (prefs.labelId == nil or hasLabel(issue, prefs.labelId))
		if keep then
			table.insert(out, issue)
		end
		seen[issue.id] = true
	end
	table.sort(out, lessWith(compareBoard))
	return out
end

-- ─── Columns ────────────────────────────────────────────────────────────────

local function inList(list: { string }, value: string): boolean
	return table.find(list, value) ~= nil
end

local function teamColumns(visible: { Issue }, team: Team, stateTypes: { string }): { Column }
	local columns: { Column } = {}
	local byState: { [string]: Column } = {}
	for _, state in team.states do
		if inList(stateTypes, state.type) then
			local column: Column = {
				id = state.id,
				title = state.name,
				stateType = state.type,
				stateId = state.id,
				color = state.color,
				issues = {},
			}
			table.insert(columns, column)
			byState[state.id] = column
		end
	end
	for _, issue in visible do
		local column = byState[issue.state.id]
		if column ~= nil then
			table.insert(column.issues, issue)
		end
	end
	return columns
end

-- Duplicate is a flavour of canceled on a "my issues" board.
local function mineColumnType(stateType: string): string
	return if stateType == "duplicate" then "canceled" else stateType
end

local function mineColumns(visible: { Issue }, stateTypes: { string }): { Column }
	local columns: { Column } = {}
	local byType: { [string]: Column } = {}
	for _, stateType in stateTypes do
		if stateType ~= "duplicate" then
			local column: Column = {
				id = stateType,
				title = model.TYPE_TITLES[stateType] or stateType,
				stateType = stateType,
				stateId = nil,
				color = nil,
				issues = {},
			}
			table.insert(columns, column)
			byType[stateType] = column
		end
	end
	for _, issue in visible do
		local column = byType[mineColumnType(issue.state.type)]
		if column ~= nil then
			table.insert(column.issues, issue)
		end
	end
	-- Issues of one type come from several teams whose state positions differ; order cards by priority only.
	for _, column in columns do
		table.sort(column.issues, lessWith(compareCard))
	end
	return columns
end

function model.columns(visible: { Issue }, prefs: Prefs, team: Team?): { Column }
	local stateTypes = model.viewTypes(prefs.view)
	if prefs.scope == "team" and team ~= nil then
		return teamColumns(visible, team, stateTypes)
	end
	return mineColumns(visible, stateTypes)
end

-- ─── Table sorting ──────────────────────────────────────────────────────────

local function compareTitle(a: Issue, b: Issue): number
	return compareText(a.title, b.title)
end

local function comparePriority(a: Issue, b: Issue): number
	return compare(priorityRank(a.priority), priorityRank(b.priority))
end

-- Unassigned issues sort after every named assignee.
local function compareAssignee(a: Issue, b: Issue): number
	local left, right = a.assignee, b.assignee
	if left == nil or right == nil then
		return compare(if left == nil then 1 else 0, if right == nil then 1 else 0)
	end
	return compareText(left.name, right.name)
end

local function compareUpdated(a: Issue, b: Issue): number
	return compare(model.epoch(a.updatedAt) or 0, model.epoch(b.updatedAt) or 0)
end

local TABLE_COMPARATORS: { [string]: (Issue, Issue) -> number } = {
	identifier = compareIdentifier,
	title = compareTitle,
	state = compareState,
	priority = comparePriority,
	assignee = compareAssignee,
	updated = compareUpdated,
}

function model.sortTable(visible: { Issue }, key: string, asc: boolean): { Issue }
	local base = TABLE_COMPARATORS[key] or compareIdentifier
	local out = table.clone(visible)
	table.sort(
		out,
		lessWith(function(a: Issue, b: Issue): number
			local c = base(a, b)
			if c == 0 then
				return compareIdentifier(a, b)
			end
			return if asc then c else -c
		end)
	)
	return out
end

-- ─── Workflow states ────────────────────────────────────────────────────────

function model.stateFor(team: Team, stateType: string): WorkflowState?
	local best: WorkflowState? = nil
	for _, state in team.states do
		if state.type == stateType and (best == nil or state.position < best.position) then
			best = state
		end
	end
	return best
end

function model.doneState(team: Team): WorkflowState?
	return model.stateFor(team, "completed")
end

function model.todoState(team: Team): WorkflowState?
	return model.stateFor(team, "unstarted")
end

function model.startedState(team: Team): WorkflowState?
	return model.stateFor(team, "started")
end

local function filterStates(states: { WorkflowState }, keep: (WorkflowState) -> boolean): { WorkflowState }
	local out: { WorkflowState } = {}
	for _, state in states do
		if keep(state) then
			table.insert(out, state)
		end
	end
	return out
end

local function indexOfState(states: { WorkflowState }, id: string): number?
	for index, state in states do
		if state.id == id then
			return index
		end
	end
	return nil
end

-- The state one column before (delta < 0) or after (delta > 0) the issue's, or nil at the edge.
-- Columns are the team's states of the view's types; an issue outside the view steps through every
-- non-duplicate state instead.
function model.adjacentState(team: Team, issue: Issue, delta: number, view: string): WorkflowState?
	local stateTypes = model.viewTypes(view)
	local candidates = filterStates(team.states, function(state: WorkflowState): boolean
		return inList(stateTypes, state.type)
	end)
	local current = indexOfState(candidates, issue.state.id)
	if current == nil then
		candidates = filterStates(team.states, function(state: WorkflowState): boolean
			return state.type ~= "duplicate" or state.id == issue.state.id
		end)
		current = indexOfState(candidates, issue.state.id)
	end
	if current == nil then
		return nil
	end
	return candidates[current + delta]
end

-- ─── Forms ──────────────────────────────────────────────────────────────────

-- name → current value, for every field that differs from its baseline.
function model.formDiff(form: Form): { [string]: string }
	local changed: { [string]: string } = {}
	for _, field in form.fields do
		local current = ""
		if field.kind == "choice" then
			current = field.value or ""
		elseif field.field ~= nil then
			current = field.field.text
		end
		if current ~= field.baseline then
			changed[field.name] = current
		end
	end
	return changed
end

-- ─── Projects ───────────────────────────────────────────────────────────────

local PROJECT_STATUS_TYPES: { string } =
	table.freeze({ "backlog", "planned", "started", "paused", "completed", "canceled" })
model.PROJECT_STATUS_TYPES = PROJECT_STATUS_TYPES

local PROJECT_VIEW_TYPES: { [string]: { string } } = {
	active = table.freeze({ "planned", "started", "paused" }),
	backlog = table.freeze({ "backlog" }),
	all = PROJECT_STATUS_TYPES,
}

local HEALTHS: { { value: string, label: string } } = {
	{ value = "onTrack", label = "On track" },
	{ value = "atRisk", label = "At risk" },
	{ value = "offTrack", label = "Off track" },
}
model.HEALTHS = HEALTHS

-- Worst first, so an ascending health sort leads with the projects that need attention.
local HEALTH_RANK: { [string]: number } = { offTrack = 1, atRisk = 2, onTrack = 3 }
local NO_HEALTH_RANK = 4

function model.projectStatusRank(t: string): number
	return table.find(PROJECT_STATUS_TYPES, t) or #PROJECT_STATUS_TYPES + 1
end

function model.projectViewTypes(view: string): { string }
	return PROJECT_VIEW_TYPES[view] or PROJECT_VIEW_TYPES.active
end

function model.healthLabel(health: string?): string
	for _, entry in HEALTHS do
		if entry.value == health then
			return entry.label
		end
	end
	return "No update"
end

-- 0..1 → "0%"…"100%", rounded down so a project shows 100% only when it is complete.
function model.progressLabel(progress: number): string
	return `{math.floor(math.clamp(progress, 0, 1) * 100 + 1e-9)}%`
end

-- "YYYY-MM-DD" (or an ISO timestamp) → "Mar 4", with the year when it is not the year of `now`.
function model.shortDate(date: string, now: number): string
	local at = model.epoch(string.sub(date, 1, 10))
	if at == nil then
		return ""
	end
	local year, month, day = civilFromDays(at // SECONDS_PER_DAY)
	local currentYear = civilFromDays(now // SECONDS_PER_DAY)
	local label = `{MONTH_NAMES[month]} {day}`
	return if year == currentYear then label else `{label}, {year}`
end

-- A date at Linear's DateResolutionType precision, as Linear shows it: month "Sep 2026", quarter "Q3 2026",
-- halfYear "H2 2026", year "2026"; an exact date (nil or an unknown resolution) is model.shortDate.
function model.resolvedDate(date: string, resolution: string?, now: number): string
	local at = model.epoch(string.sub(date, 1, 10))
	if at == nil then
		return ""
	end
	local year, month = civilFromDays(at // SECONDS_PER_DAY)
	if resolution == "month" then
		return `{MONTH_NAMES[month]} {year}`
	elseif resolution == "quarter" then
		return `Q{(month - 1) // 3 + 1} {year}`
	elseif resolution == "halfYear" then
		return `H{if month <= 6 then 1 else 2} {year}`
	elseif resolution == "year" then
		return tostring(year)
	end
	return model.shortDate(date, now)
end

-- Linear ProjectFilter as plain tables; `{}` (no condition) when every project of the organization is wanted.
-- Archived projects are excluded by the query itself (includeArchived defaults to false).
function model.projectServerFilter(prefs: Prefs): any
	local parts: { any } = {}
	if prefs.projectScope == "mine" then
		local leadOrMember: { any } = {
			{ lead = { isMe = { eq = true } } },
			{ members = { some = { isMe = { eq = true } } } },
		}
		table.insert(parts, { ["or"] = leadOrMember })
	elseif prefs.projectScope == "team" and prefs.projectTeamId ~= nil then
		table.insert(parts, { accessibleTeams = { some = { id = { eq = prefs.projectTeamId } } } })
	end
	if prefs.projectView ~= "all" then
		table.insert(parts, { status = { type = { ["in"] = model.projectViewTypes(prefs.projectView) } } })
	end
	if #parts == 0 then
		return {}
	end
	return { ["and"] = parts }
end

local function compareProjectStatus(a: Project, b: Project): number
	local byType = compare(model.projectStatusRank(a.status.type), model.projectStatusRank(b.status.type))
	if byType ~= 0 then
		return byType
	end
	local byPosition = compare(a.status.position, b.status.position)
	return if byPosition ~= 0 then byPosition else compareText(a.status.name, b.status.name)
end

local function compareProjectName(a: Project, b: Project): number
	return compareText(a.name, b.name)
end

-- Inside a column: priority (1..4, then none), then Linear's manual order, then name.
local function compareProjectCard(a: Project, b: Project): number
	local byPriority = compare(priorityRank(a.priority), priorityRank(b.priority))
	if byPriority ~= 0 then
		return byPriority
	end
	local bySortOrder = compare(a.sortOrder, b.sortOrder)
	return if bySortOrder ~= 0 then bySortOrder else compareProjectName(a, b)
end

local function lessProjects(compareWith: (Project, Project) -> number): (Project, Project) -> boolean
	return function(a: Project, b: Project): boolean
		local c = compareWith(a, b)
		if c ~= 0 then
			return c < 0
		end
		return a.id < b.id
	end
end

local function projectHaystack(project: Project): string
	local parts: { string } = { project.name }
	local lead = project.lead
	if lead ~= nil then
		table.insert(parts, lead.name)
		table.insert(parts, lead.displayName)
	end
	for _, team in project.teams do
		table.insert(parts, team.key)
	end
	return string.lower(table.concat(parts, "\n"))
end

local function matchesLead(project: Project, wanted: string, viewerId: string?): boolean
	local lead = project.lead
	if wanted == "none" then
		return lead == nil
	end
	local id = if wanted == "me" then viewerId else wanted
	return lead ~= nil and id ~= nil and lead.id == id
end

local function matchesHealth(project: Project, wanted: string): boolean
	if wanted == "none" then
		return project.health == nil
	end
	return project.health == wanted
end

-- Client filters (query over name, lead and team keys; lead; health), deduped by id, in board order:
-- status (type rank, position), then priority, sortOrder and name.
function model.visibleProjects(projects: { Project }, prefs: Prefs, query: string, viewerId: string?): { Project }
	local needle = string.lower(string.match(query, "^%s*(.-)%s*$") :: string)
	local seen: { [string]: boolean } = {}
	local out: { Project } = {}
	for _, project in projects do
		local keep = not seen[project.id]
			and (needle == "" or string.find(projectHaystack(project), needle, 1, true) ~= nil)
			and (prefs.projectLead == nil or matchesLead(project, prefs.projectLead, viewerId))
			and (prefs.projectHealth == nil or matchesHealth(project, prefs.projectHealth))
		if keep then
			table.insert(out, project)
		end
		seen[project.id] = true
	end
	table.sort(
		out,
		lessProjects(function(a: Project, b: Project): number
			local byStatus = compareProjectStatus(a, b)
			return if byStatus ~= 0 then byStatus else compareProjectCard(a, b)
		end)
	)
	return out
end

local function statusOrder(a: ProjectStatus, b: ProjectStatus): boolean
	local rankA, rankB = model.projectStatusRank(a.type), model.projectStatusRank(b.type)
	if rankA ~= rankB then
		return rankA < rankB
	end
	if a.position ~= b.position then
		return a.position < b.position
	end
	return a.id < b.id
end

-- One column per organization status whose type is in the view (empty ones included), ordered by type rank
-- then position. A project whose status is missing from `statuses` (stale list) gets a column of its own.
function model.projectColumns(visible: { Project }, prefs: Prefs, statuses: { ProjectStatus }): { ProjectColumn }
	local viewTypes = model.projectViewTypes(prefs.projectView)
	local wanted: { ProjectStatus } = {}
	local known: { [string]: boolean } = {}
	local function want(status: ProjectStatus)
		if not known[status.id] and inList(viewTypes, status.type) then
			known[status.id] = true
			table.insert(wanted, status)
		end
	end
	for _, status in statuses do
		want(status)
	end
	for _, project in visible do
		want(project.status)
	end
	table.sort(wanted, statusOrder)

	local columns: { ProjectColumn } = {}
	local byStatus: { [string]: ProjectColumn } = {}
	for _, status in wanted do
		local column: ProjectColumn = {
			id = status.id,
			title = status.name,
			statusType = status.type,
			statusId = status.id,
			color = status.color,
			projects = {},
		}
		table.insert(columns, column)
		byStatus[status.id] = column
	end
	for _, project in visible do
		local column = byStatus[project.status.id]
		if column ~= nil then
			table.insert(column.projects, project)
		end
	end
	for _, column in columns do
		table.sort(column.projects, lessProjects(compareProjectCard))
	end
	return columns
end

local function healthRank(health: string?): number
	return if health ~= nil then HEALTH_RANK[health] or NO_HEALTH_RANK else NO_HEALTH_RANK
end

-- 1 when only `a` is missing, -1 when only `b` is: missing values (no lead, no target date) sort last.
local function missingOrder(aMissing: boolean, bMissing: boolean): number
	return compare(if aMissing then 1 else 0, if bMissing then 1 else 0)
end

local PROJECT_COMPARATORS: { [string]: (Project, Project) -> number } = {
	name = compareProjectName,
	status = compareProjectStatus,
	health = function(a: Project, b: Project): number
		return compare(healthRank(a.health), healthRank(b.health))
	end,
	lead = function(a: Project, b: Project): number
		local left, right = a.lead, b.lead
		if left == nil or right == nil then
			return missingOrder(left == nil, right == nil)
		end
		return compareText(left.name, right.name)
	end,
	target = function(a: Project, b: Project): number
		local left, right = a.targetDate, b.targetDate
		if left == nil or right == nil then
			return missingOrder(left == nil, right == nil)
		end
		return compare(model.epoch(left) or 0, model.epoch(right) or 0)
	end,
	progress = function(a: Project, b: Project): number
		return compare(a.progress, b.progress)
	end,
	updated = function(a: Project, b: Project): number
		return compare(model.epoch(a.updatedAt) or 0, model.epoch(b.updatedAt) or 0)
	end,
}

model.PROJECT_SORT_KEYS = table.freeze({ "name", "status", "health", "lead", "target", "progress", "updated" })

-- Table order for projects mode; ties fall back to the name. Unknown keys sort by name.
function model.sortProjects(visible: { Project }, key: string, asc: boolean): { Project }
	local base = PROJECT_COMPARATORS[key] or compareProjectName
	local out = table.clone(visible)
	table.sort(
		out,
		lessProjects(function(a: Project, b: Project): number
			local c = base(a, b)
			if c == 0 then
				return compareProjectName(a, b)
			end
			return if asc then c else -c
		end)
	)
	return out
end

-- ─── Project page ───────────────────────────────────────────────────────────

-- The project page's tabs in tab-bar order. A layer that adds a tab appends it here (and to types.ProjectTab).
local PROJECT_TABS: { { id: ProjectTab, label: string } } = table.freeze({
	table.freeze({ id = "overview" :: ProjectTab, label = "Overview" }),
	table.freeze({ id = "activity" :: ProjectTab, label = "Activity" }),
})
model.PROJECT_TABS = PROJECT_TABS

-- The tab named `id`, or nil when no tab has that id (a saved tab a later version dropped).
function model.projectTab(id: any): ProjectTab?
	for _, tab in PROJECT_TABS do
		if tab.id == id then
			return tab.id
		end
	end
	return nil
end

-- The tab `delta` steps from `current`, wrapping around; the first tab when `current` is unknown.
function model.stepProjectTab(current: ProjectTab, delta: number): ProjectTab
	local index = 0
	for position, tab in PROJECT_TABS do
		if tab.id == current then
			index = position
		end
	end
	if index == 0 then
		return PROJECT_TABS[1].id
	end
	return PROJECT_TABS[(index - 1 + delta) % #PROJECT_TABS + 1].id
end

local MILESTONE_STATUS_LABELS: { [string]: string } = {
	unstarted = "Not started",
	next = "Next",
	overdue = "Overdue",
	done = "Done",
}

-- ProjectMilestoneStatus → label; unknown statuses read as not started.
function model.milestoneStatusLabel(status: string): string
	return MILESTONE_STATUS_LABELS[status] or MILESTONE_STATUS_LABELS.unstarted
end

-- Linear's milestone order: sortOrder, then target date (none last), then name, then id. Returns a new list.
function model.sortMilestones(milestones: { ProjectMilestone }): { ProjectMilestone }
	local out = table.clone(milestones)
	table.sort(out, function(a: ProjectMilestone, b: ProjectMilestone): boolean
		if a.sortOrder ~= b.sortOrder then
			return a.sortOrder < b.sortOrder
		end
		local left, right = a.targetDate, b.targetDate
		if left ~= right then
			if left == nil or right == nil then
				return right == nil
			end
			return left < right
		end
		local byName = compareText(a.name, b.name)
		if byName ~= 0 then
			return byName < 0
		end
		return a.id < b.id
	end)
	return out
end

-- "ada, grace, linus" with at most `max` names, then "+N" for the rest; "" for none.
function model.namesLabel(names: { string }, max: number): string
	if #names <= max then
		return table.concat(names, ", ")
	end
	local shown = table.move(names, 1, max, 1, {})
	return `{table.concat(shown, ", ")} +{#names - max}`
end

-- ─── Project activity ───────────────────────────────────────────────────────

-- Display names the Activity tab resolves ids with: users, teams and the project's milestones, by id.
export type ActivityNames = {
	users: { [string]: string },
	teams: { [string]: string },
	milestones: { [string]: string },
}

-- One history event the Activity tab can describe: `actor` (nil for events without one, e.g. a milestone that
-- completed) and `text` read as one line, "<actor> <text>".
export type HistoryEvent = {
	-- The event's `type` (status, startDate, …).
	kind: string,
	-- Epoch seconds.
	time: number,
	actor: string?,
	text: string,
}

-- One row of the Activity tab: a project update or a history event, `time` in epoch seconds.
export type ActivityItem = {
	-- Update id, or "<history record id>:<entry index>".
	id: string,
	time: number,
	update: types.ProjectUpdate?,
	event: HistoryEvent?,
}

export type ActivityTimeline = {
	-- Newest first; only items no unloaded page can precede (see model.activityTimeline).
	items: { ActivityItem },
	-- A source has another page (`Load more`).
	more: boolean,
}

local UNKNOWN_ACTOR = "Someone"

-- Names for `users` (display name), `teams` and `milestones` (name); later entries never replace earlier ones.
function model.activityNames(
	users: { types.User },
	teams: { { id: string, name: string } },
	milestones: { ProjectMilestone }
): ActivityNames
	local names: ActivityNames = { users = {}, teams = {}, milestones = {} }
	for _, user in users do
		if names.users[user.id] == nil then
			names.users[user.id] = if user.displayName ~= "" then user.displayName else user.name
		end
	end
	for _, team in teams do
		if names.teams[team.id] == nil then
			names.teams[team.id] = team.name
		end
	end
	for _, milestone in milestones do
		if names.milestones[milestone.id] == nil then
			names.milestones[milestone.id] = milestone.name
		end
	end
	return names
end

local function nonEmpty(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

-- "<a>", "<a> and <b>", "<a>, <b> and <c>".
local function joinNames(names: { string }): string
	if #names <= 1 then
		return names[1] or ""
	end
	return `{table.concat(names, ", ", 1, #names - 1)} and {names[#names]}`
end

-- The actor of an entry: `actorId`, else every `actorIds` member; an id nobody resolves reads "Someone"
-- (an integration's `source.displayName` when it has one). nil when the entry names no actor.
local function entryActor(entry: any, names: ActivityNames): string?
	local ids: { string } = {}
	if type(entry.actorId) == "string" then
		table.insert(ids, entry.actorId)
	elseif type(entry.actorIds) == "table" then
		for _, id in ipairs(entry.actorIds) do
			if type(id) == "string" then
				table.insert(ids, id)
			end
		end
	end
	if #ids == 0 then
		return nil
	end
	local resolved: { string } = {}
	local unknown = false
	for _, id in ids do
		local name = names.users[id]
		if name ~= nil then
			table.insert(resolved, name)
		else
			unknown = true
		end
	end
	if unknown then
		local source = entry.source
		local via = if type(source) == "table" then nonEmpty(source.displayName) else nil
		table.insert(resolved, via or UNKNOWN_ACTOR)
	end
	return joinNames(resolved)
end

-- Names of one side (added or removed) of a list event; `unknown` counts ids no name resolves.
type NamedSide = { names: { string }, unknown: number }

-- A milestone reference `{id, name}`: its name, else the project's name for that id (Linear sends `name` empty).
-- nil when the value is not such a reference; "" when neither names it.
local function milestoneName(value: any, names: ActivityNames): string?
	if type(value) ~= "table" or type(value.id) ~= "string" then
		return nil
	end
	return nonEmpty(value.name) or names.milestones[value.id] or ""
end

-- The names of a list of milestone references; unnamed ones count as unknown. nil when it is not such a list.
local function milestoneList(value: any, names: ActivityNames): NamedSide?
	if type(value) ~= "table" then
		return nil
	end
	local side: NamedSide = { names = {}, unknown = 0 }
	for _, item in ipairs(value) do
		local name = milestoneName(item, names)
		if name == nil then
			return nil
		elseif name == "" then
			side.unknown += 1
		else
			table.insert(side.names, name)
		end
	end
	return side
end

-- Team names of a list of team ids; nil when the value is not a list of strings.
local function teamList(value: any, names: ActivityNames): NamedSide?
	if type(value) ~= "table" then
		return nil
	end
	local side: NamedSide = { names = {}, unknown = 0 }
	for _, id in ipairs(value) do
		if type(id) ~= "string" then
			return nil
		end
		local name = names.teams[id]
		if name ~= nil then
			table.insert(side.names, name)
		else
			side.unknown += 1
		end
	end
	return side
end

-- "added team Design", "added teams Design and Engineering", "added a team", "added 2 teams",
-- "added teams Design and 1 other"; nil for an empty side.
local function sidePhrase(verb: string, noun: string, side: NamedSide): string?
	local count = #side.names + side.unknown
	if count == 0 then
		return nil
	elseif #side.names == 0 then
		return if count == 1 then `{verb} a {noun}` else `{verb} {count} {noun}s`
	end
	local list = table.clone(side.names)
	if side.unknown > 0 then
		table.insert(list, if side.unknown == 1 then "1 other" else `{side.unknown} others`)
	end
	return `{verb} {if count == 1 then noun else noun .. "s"} {joinNames(list)}`
end

-- "added milestone Alpha and removed milestones Beta and Gamma"; nil when both sides are empty.
local function addedRemoved(noun: string, added: NamedSide, removed: NamedSide): string?
	local add = sidePhrase("added", noun, added)
	local remove = sidePhrase("removed", noun, removed)
	if add ~= nil and remove ~= nil then
		return `{add} and {remove}`
	end
	return add or remove
end

-- Describers per entry `type` (the kinds observed in live data; docs/ARCHITECTURE.md lists them). Each returns the
-- line's text, or nil when the entry does not have the shape that kind was seen with.
local HISTORY_KINDS: { [string]: (entry: any, names: ActivityNames, now: number) -> string? } = {
	status = function(entry)
		local from = if type(entry.fromStatus) == "table" then nonEmpty(entry.fromStatus.name) else nil
		local to = if type(entry.toStatus) == "table" then nonEmpty(entry.toStatus.name) else nil
		if to == nil then
			return nil
		end
		return if from ~= nil then `changed status from {from} to {to}` else `changed status to {to}`
	end,
	startDate = function(entry, _names, now)
		local to = nonEmpty(entry.to)
		local label = if to ~= nil then model.shortDate(to, now) else ""
		return if label ~= "" then `set the start date to {label}` else nil
	end,
	name = function(entry)
		local from = nonEmpty(entry.from)
		local to = nonEmpty(entry.to)
		if to == nil then
			return nil
		end
		return if from ~= nil then `renamed the project from {from} to {to}` else `renamed the project to {to}`
	end,
	icon = function()
		return "changed the icon"
	end,
	content = function()
		return "updated the description"
	end,
	description = function()
		return "updated the summary"
	end,
	leadTeamId = function(entry, names)
		local from = if type(entry.from) == "string" then names.teams[entry.from] else nil
		local to = if type(entry.to) == "string" then names.teams[entry.to] else nil
		if from ~= nil and to ~= nil then
			return `changed the lead team from {from} to {to}`
		elseif to ~= nil then
			return `changed the lead team to {to}`
		end
		return "changed the lead team"
	end,
	teams = function(entry, names)
		local added = teamList(entry.added or {}, names)
		local removed = teamList(entry.removed or {}, names)
		if added == nil or removed == nil then
			return nil
		end
		return addedRemoved("team", added, removed)
	end,
	milestones = function(entry, names)
		local added = milestoneList(entry.added or {}, names)
		local removed = milestoneList(entry.removed or {}, names)
		if added == nil or removed == nil then
			return nil
		end
		return addedRemoved("milestone", added, removed)
	end,
	milestone_completion = function(entry, names)
		local name = milestoneName(entry.milestone, names)
		if name == nil then
			return nil
		end
		return if name ~= "" then `Milestone {name} completed` else "A milestone was completed"
	end,
}

-- Kinds that never name an actor: their text is the whole line.
local ACTORLESS: { [string]: boolean } = { milestone_completion = true }

-- One raw `ProjectHistory.entries` element as a line, or nil when its kind is unknown or its shape is not the one
-- observed (no `type`, no numeric `at`, missing fields). Ids resolve through `names`; `now` dates short dates.
function model.historyEvent(entry: any, names: ActivityNames, now: number): HistoryEvent?
	if type(entry) ~= "table" or type(entry.type) ~= "string" or type(entry.at) ~= "number" then
		return nil
	end
	local describe = HISTORY_KINDS[entry.type]
	if describe == nil then
		return nil
	end
	local ok, line = pcall(describe, entry, names, now)
	if not ok or type(line) ~= "string" then
		return nil
	end
	local actor: string? = nil
	if not ACTORLESS[entry.type] then
		actor = entryActor(entry, names) or UNKNOWN_ACTOR
	end
	return { kind = entry.type, time = entry.at / 1000, actor = actor, text = line }
end

-- The oldest time of a source with more pages: anything older may still be preceded by an unloaded item.
local function sourceFloor<T>(source: types.ActivitySource<T>, timeOf: (T) -> number?): number?
	if not source.hasMore then
		return nil
	end
	local floor: number? = nil
	for _, item in source.items do
		local time = timeOf(item)
		if time ~= nil and (floor == nil or time < floor) then
			floor = time
		end
	end
	return floor
end

local function updateTime(update: types.ProjectUpdate): number?
	return model.epoch(update.createdAt)
end

local function recordTime(record: types.ProjectHistoryRecord): number?
	return model.epoch(record.updatedAt)
end

-- The Activity tab's timeline: updates and the history events `historyEvent` describes, newest first (ties by
-- id). Items older than a source's oldest loaded item while that source has more pages are held back, so loading
-- the next page never inserts anything above an item already shown.
function model.activityTimeline(activity: types.ProjectActivity, names: ActivityNames, now: number): ActivityTimeline
	local items: { ActivityItem } = {}
	for _, update in activity.updates.items do
		local time = updateTime(update)
		if time ~= nil then
			table.insert(items, { id = update.id, time = time, update = update, event = nil })
		end
	end
	for _, record in activity.history.items do
		for index, entry in record.entries do
			local event = model.historyEvent(entry, names, now)
			if event ~= nil then
				table.insert(items, { id = `{record.id}:{index}`, time = event.time, update = nil, event = event })
			end
		end
	end
	local cutoff = sourceFloor(activity.updates, updateTime)
	local historyFloor = sourceFloor(activity.history, recordTime)
	if historyFloor ~= nil and (cutoff == nil or historyFloor > cutoff) then
		cutoff = historyFloor
	end
	local shown: { ActivityItem } = {}
	for _, item in items do
		if cutoff == nil or item.time >= cutoff then
			table.insert(shown, item)
		end
	end
	table.sort(shown, function(a: ActivityItem, b: ActivityItem): boolean
		if a.time ~= b.time then
			return a.time > b.time
		end
		return a.id < b.id
	end)
	return { items = shown, more = activity.updates.hasMore or activity.history.hasMore }
end

-- The cursors `Load more` sends: each source with another page; nil when no source has one.
function model.activityCursors(activity: types.ProjectActivity): types.ActivityCursors?
	local updates = if activity.updates.hasMore then activity.updates.cursor else nil
	local history = if activity.history.hasMore then activity.history.cursor else nil
	if updates == nil and history == nil then
		return nil
	end
	return { updates = updates, history = history }
end

-- A reloaded first page merged over what was loaded: the fresh page wins, the older pages loaded with `Load more`
-- stay (items older than the fresh page's oldest, minus the ones the fresh page carries), with their cursor.
local function reloadSource<T>(
	old: types.ActivitySource<T>,
	fresh: types.ActivitySource<T>,
	idOf: (T) -> string,
	timeOf: (T) -> number?
): types.ActivitySource<T>
	local freshIds: { [string]: boolean } = {}
	local oldest: number? = nil
	for _, item in fresh.items do
		freshIds[idOf(item)] = true
		local time = timeOf(item)
		if time ~= nil and (oldest == nil or time < oldest) then
			oldest = time
		end
	end
	if not fresh.hasMore or oldest == nil then
		return fresh
	end
	local items = table.clone(fresh.items)
	local kept = 0
	for _, item in old.items do
		local time = timeOf(item)
		if not freshIds[idOf(item)] and time ~= nil and time < oldest then
			table.insert(items, item)
			kept += 1
		end
	end
	if kept == 0 then
		return fresh
	end
	return { items = items, cursor = old.cursor, hasMore = old.hasMore }
end

local function updateId(update: types.ProjectUpdate): string
	return update.id
end

local function recordId(record: types.ProjectHistoryRecord): string
	return record.id
end

-- A reload of the first pages (`r`, the poll tick) applied over `old` (nil: the first load).
function model.activityReloaded(old: types.ProjectActivity?, fresh: types.ProjectActivity): types.ProjectActivity
	if old == nil then
		return fresh
	end
	return {
		updates = reloadSource(old.updates, fresh.updates, updateId, updateTime),
		history = reloadSource(old.history, fresh.history, recordId, recordTime),
	}
end

local function appendSource<T>(
	old: types.ActivitySource<T>,
	page: types.ActivitySource<T>,
	idOf: (T) -> string
): types.ActivitySource<T>
	local seen: { [string]: boolean } = {}
	local items = table.clone(old.items)
	for _, item in items do
		seen[idOf(item)] = true
	end
	for _, item in page.items do
		if not seen[idOf(item)] then
			seen[idOf(item)] = true
			table.insert(items, item)
		end
	end
	return { items = items, cursor = page.cursor, hasMore = page.hasMore }
end

-- The next pages (`Load more` with `cursors`) appended to `old`; sources without a cursor stay as they were.
function model.activityAppended(
	old: types.ProjectActivity,
	page: types.ProjectActivity,
	cursors: types.ActivityCursors
): types.ProjectActivity
	return {
		updates = if cursors.updates ~= nil then appendSource(old.updates, page.updates, updateId) else old.updates,
		history = if cursors.history ~= nil then appendSource(old.history, page.history, recordId) else old.history,
	}
end

-- "Nov 22, 2026, 19:47" in the host's local time (the title of a relative time).
function model.absoluteTime(at: number): string
	local t = os.date("*t", math.floor(at)) :: { [string]: any }
	return string.format("%s %d, %d, %02d:%02d", MONTH_NAMES[t.month], t.day, t.year, t.hour, t.min)
end

return model
