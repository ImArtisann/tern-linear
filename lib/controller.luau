--!strict
-- The `linear.board` block: state, requests, polling, forms, keys and events.
-- The controller is the only module that mutates `BlockState`; views only read it.
-- Contract: docs/ARCHITECTURE.md (request discipline, actions, select keys, keys).

local credentials = require("./credentials")
local linear = require("./linear")
local model = require("./model")
local text = require("./text")
local types = require("./types")
local view = require("./view")

type BlockState = types.BlockState
type Issue = types.Issue
type Project = types.Project
type Team = types.Team
type ApiError = types.ApiError
type Field = types.Field
type Form = types.Form
type FormField = types.FormField
type FormOption = types.FormOption
type Mode = types.Mode
type Prefs = types.Prefs
type Patch = { [string]: any }

local POLL_MS = 30000
local FULL_RELOAD_MS = 300000
local NOTICE_MS = 4000
local DETAIL_DEBOUNCE_MS = 250
local DEFAULT_BACKOFF_MS = 60000

local SORT_KEYS: { [string]: boolean } = {
	identifier = true,
	title = true,
	state = true,
	priority = true,
	assignee = true,
	updated = true,
}

local PROJECT_SORT_KEYS: { [string]: boolean } = {}
for _, key in model.PROJECT_SORT_KEYS do
	PROJECT_SORT_KEYS[key] = true
end

-- ─── Run registry ───────────────────────────────────────────────────────────
-- One Run per live block. Pane ids are reused after a restart, so every
-- callback checks that the registry still maps its pane to *its* state.

type Run = {
	state: BlockState,
	cfg: types.Config?,
	poll: TimerHandle?,
	noticeTimer: TimerHandle?,
	detailTimer: TimerHandle?,
	-- Bumped whenever the drawer's detail request is superseded.
	detailToken: number,
	-- Bumped whenever the project page's detail request is superseded (page closed, reopened, reloaded).
	pageToken: number,
	-- The same for the page's activity requests (first load, reloads, Load more).
	activityToken: number,
	-- Bumped when a Projects list request starts; see `goneProjects`.
	projectsSeq: number,
	-- Projects whose page answered `notfound`, mapped to `projectsSeq` at that moment: a list result from a request
	-- that started no later leaves them out; a later one is authoritative and drops the entry.
	goneProjects: { [string]: number },
	-- A notice reported while the first load runs (the loading view shows none); it starts once the list shows.
	readyNotice: string?,
	-- The same for the Issues tab's requests (loads and change checks).
	issuesToken: number,
	-- An Issues tab request is in flight; the poll tick waits for it.
	issuesInFlight: boolean,
	-- tern.now() of the Issues tab's last successful load (its 5-minute full reload).
	issuesFullAt: number,
	-- What the in-flight foreground request is: only loads may supersede loads.
	fgKind: ("load" | "mutation")?,
	-- tern.now() of the last successful board load.
	lastFullAt: number,
	focusQueued: boolean,
	-- A reload was asked for while another background read was in flight.
	reloadQueued: boolean,
	-- `e` pressed before the detail arrived: open the edit form once it does.
	editAfterLoad: string?,
	-- The viewer and team list loaded; until then polls retry the full load instead of the issues alone.
	metaReady: boolean,
}

local runs: { [number]: Run } = {}

local function runOf(state: BlockState): Run?
	local run = runs[state.cx.pane]
	if run ~= nil and run.state == state then
		return run
	end
	return nil
end

local function cancelTimer(handle: TimerHandle?)
	if handle ~= nil then
		handle:cancel()
	end
end

local function retire(run: Run)
	cancelTimer(run.poll)
	cancelTimer(run.noticeTimer)
	cancelTimer(run.detailTimer)
	run.poll = nil
	run.noticeTimer = nil
	run.detailTimer = nil
	if runs[run.state.cx.pane] == run then
		runs[run.state.cx.pane] = nil
	end
end

local function paneExists(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

-- The run of a block that is still on screen; retires runs whose pane is gone.
local function liveRun(state: BlockState): Run?
	local run = runOf(state)
	if run == nil then
		return nil
	end
	if not paneExists(state.cx.pane) then
		retire(run)
		return nil
	end
	return run
end

-- ─── Pure helpers ───────────────────────────────────────────────────────────

local function nowMs(): number
	return os.time() * 1000
end

local function unknownError(): ApiError
	return { kind = "server", message = "Linear returned no data." }
end

-- Event values and saved prefs: the value when it is one of the allowed strings, else nil. The allowed sets are
-- scoped to the block below (the controller's top level is close to Luau's 200-local limit).
local parse = {}
do
	local VIEWS: { [string]: "active" | "backlog" | "all" } = { active = "active", backlog = "backlog", all = "all" }
	local LAYOUTS: { [string]: "board" | "table" } = { board = "board", table = "table" }
	local MODES: { [string]: Mode } = { projects = "projects", issues = "issues" }
	local LINK_MODES: { [string]: "blocked-by" | "blocks" | "related" } = {
		["blocked-by"] = "blocked-by",
		blocks = "blocks",
		related = "related",
	}

	function parse.view(value: any): ("active" | "backlog" | "all")?
		return if type(value) == "string" then VIEWS[value] else nil
	end

	function parse.layout(value: any): ("board" | "table")?
		return if type(value) == "string" then LAYOUTS[value] else nil
	end

	function parse.linkMode(value: any): ("blocked-by" | "blocks" | "related")?
		return if type(value) == "string" then LINK_MODES[value] else nil
	end

	function parse.mode(value: any): Mode?
		return if type(value) == "string" then MODES[value] else nil
	end
end

-- Every saved field is checked against its allowed values; anything else falls back.
local function restorePrefs(saved: any): Prefs
	local prefs: Prefs = {
		mode = "projects",
		scope = "mine",
		view = "active",
		layout = "board",
		sort = "updated",
		sortAsc = false,
		projectScope = "all",
		projectView = "active",
		projectSort = "updated",
		projectSortAsc = false,
	}
	if type(saved) ~= "table" then
		return prefs
	end
	local data = saved :: { [string]: any }
	prefs.mode = parse.mode(data.mode) or prefs.mode
	if type(data.teamId) == "string" then
		prefs.teamId = data.teamId
		if data.scope == "team" then
			prefs.scope = "team"
		end
	end
	prefs.view = parse.view(data.view) or prefs.view
	prefs.layout = parse.layout(data.layout) or prefs.layout
	if type(data.sort) == "string" and SORT_KEYS[data.sort] then
		prefs.sort = data.sort
	end
	if type(data.sortAsc) == "boolean" then
		prefs.sortAsc = data.sortAsc
	end
	if data.projectScope == "mine" then
		prefs.projectScope = "mine"
	elseif data.projectScope == "team" and type(data.projectTeamId) == "string" then
		prefs.projectScope = "team"
		prefs.projectTeamId = data.projectTeamId
	end
	prefs.projectView = parse.view(data.projectView) or prefs.projectView
	if type(data.projectSort) == "string" and PROJECT_SORT_KEYS[data.projectSort] then
		prefs.projectSort = data.projectSort
	end
	if type(data.projectSortAsc) == "boolean" then
		prefs.projectSortAsc = data.projectSortAsc
	end
	return prefs
end

local function emptyProjects(): types.ProjectsState
	return {
		items = {},
		statuses = {},
		truncated = false,
		fetchedAt = nil,
		maxUpdatedAt = nil,
		query = text.new(""),
		selectedId = nil,
	}
end

-- The project page's Issues tab: its state, requests, polling and leaving it (one table: the controller's top level is
-- close to Luau's 200-local limit). The requests are defined with the project page below.
local projectIssues = {}

-- The Issues tab before its first show: nothing loaded, the Active view, no milestone, no filters, newest first.
function projectIssues.new(): types.ProjectIssuesState
	return {
		items = {},
		truncated = false,
		fetchedAt = nil,
		maxUpdatedAt = nil,
		loading = false,
		error = nil,
		stale = false,
		view = "active",
		milestoneId = nil,
		priority = nil,
		assignee = nil,
		labelId = nil,
		query = text.new(""),
		sort = "updated",
		sortAsc = false,
		selectedId = nil,
	}
end

-- A project page with nothing loaded yet: the detail loads at once, the activity and the issues when their tab is
-- first shown.
local function newPage(id: string, tab: types.ProjectTab): types.ProjectPageState
	return {
		projectId = id,
		tab = tab,
		detail = nil,
		loading = true,
		error = nil,
		fetchedAt = nil,
		activity = nil,
		activityLoading = false,
		activityPaging = false,
		activityError = nil,
		activityFetchedAt = nil,
		expandedUpdates = {},
		issues = projectIssues.new(),
	}
end

-- A saved project page (`save().projectPage`): the project id, a known tab and the Issues tab's milestone filter
-- (checked against the project's milestones once its detail loads), else nil.
local function restorePage(saved: any): types.ProjectPageState?
	if type(saved) ~= "table" then
		return nil
	end
	local page: any = (saved :: { [string]: any }).projectPage
	if type(page) ~= "table" or type(page.id) ~= "string" or page.id == "" then
		return nil
	end
	local restored = newPage(page.id, model.projectTab(page.tab) or "overview")
	if type(page.milestoneId) == "string" and page.milestoneId ~= "" then
		restored.issues.milestoneId = page.milestoneId
	end
	return restored
end

local function newState(cx: BlockCx, prefs: Prefs): BlockState
	return {
		cx = cx,
		phase = "loading",
		keySource = nil,
		setupKey = text.new(""),
		setupError = nil,
		viewer = nil,
		teams = {},
		issues = {},
		truncated = false,
		fetchedAt = nil,
		maxUpdatedAt = nil,
		projects = emptyProjects(),
		projectPage = nil,
		prefs = prefs,
		query = text.new(""),
		focus = nil,
		selectedId = nil,
		detail = nil,
		detailLoading = false,
		drawerOpen = false,
		comment = text.new(""),
		link = nil,
		form = nil,
		busy = false,
		refreshing = false,
		reloading = false,
		controlEpoch = 0,
		generation = 0,
		error = nil,
		notice = nil,
		backoffUntil = nil,
	}
end

-- ─── The issue list on screen ───────────────────────────────────────────────
-- Issues mode's list and selection (BlockState), or the project page's Issues tab's (ProjectIssuesState) while that
-- tab is on screen (model.issueList, model.selectedIssueId). The drawer, its inputs and the issue actions work on
-- whichever is on screen; leaving the tab closes the drawer, so a drawer always belongs to the list on screen.

local function setSelectedId(state: BlockState, id: string?)
	local tab = model.issuesTab(state)
	if tab ~= nil then
		tab.selectedId = id
	else
		state.selectedId = id
	end
end

local function findIssue(state: BlockState, id: string): Issue?
	for _, issue in model.issueList(state) do
		if issue.id == id then
			return issue
		end
	end
	local detail = state.detail
	if detail ~= nil and detail.id == id then
		return detail
	end
	return nil
end

local function selectedIssue(state: BlockState): Issue?
	local id = model.selectedIssueId(state)
	if id == nil then
		return nil
	end
	return findIssue(state, id)
end

local function findProject(state: BlockState, id: string): Project?
	for _, project in state.projects.items do
		if project.id == id then
			return project
		end
	end
	return nil
end

-- A project of the list, or the open page's project (a restored page may show one the list does not hold).
local function knownProject(state: BlockState, id: string): Project?
	local page = state.projectPage
	local detail = if page ~= nil then page.detail else nil
	if detail ~= nil and detail.project.id == id then
		return detail.project
	end
	return findProject(state, id)
end

local function selectedProject(state: BlockState): Project?
	local id = state.projects.selectedId
	if id == nil then
		return nil
	end
	return findProject(state, id)
end

local function inProjects(state: BlockState): boolean
	return state.prefs.mode == "projects"
end

-- The search text on screen: issues mode's, projects mode's list's, or the Issues tab's.
local function activeQuery(state: BlockState): Field
	local tab = model.issuesTab(state)
	if tab ~= nil then
		return tab.query
	end
	return if inProjects(state) then state.projects.query else state.query
end

local function teamById(state: BlockState, id: string?): Team?
	if id == nil then
		return nil
	end
	for _, team in state.teams do
		if team.id == id then
			return team
		end
	end
	return nil
end

local function viewerId(state: BlockState): string?
	local viewer = state.viewer
	if viewer == nil then
		return nil
	end
	return viewer.user.id
end

-- The team whose workflow states form the board columns (team scope only).
local function scopeTeam(state: BlockState): Team?
	if state.prefs.scope ~= "team" then
		return nil
	end
	return teamById(state, state.prefs.teamId)
end

local function stringValue(value: any): string?
	if type(value) == "string" then
		return value
	elseif type(value) == "number" then
		return tostring(value)
	end
	return nil
end

-- ─── Focus ──────────────────────────────────────────────────────────────────
-- `state.focus` routes keys; the frame op only moves the native caret. The op
-- is deferred a tick so a field that appears in the same handler is drawn first.

local function focusTarget(state: BlockState): string?
	local focus = state.focus
	if focus == nil then
		return nil
	end
	if focus == "form" then
		local form = state.form
		if form == nil then
			return nil
		end
		local field = form.fields[form.focus]
		if field == nil or field.kind == "choice" then
			return nil
		end
		return view.fieldId("form:" .. field.name)
	end
	-- The Issues tab has its own search field.
	if focus == "search" and model.issuesTab(state) ~= nil then
		return view.fieldId("project-search")
	end
	return view.fieldId(focus)
end

local function syncFocus(state: BlockState)
	local run = runOf(state)
	if run == nil or run.focusQueued then
		return
	end
	run.focusQueued = true
	tern.timer(0, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		live.focusQueued = false
		local focusOp: { any } = { "focus", focusTarget(state) or tern.json.null }
		state.cx:frame({ focusOp })
	end)
end

local function setFocus(state: BlockState, name: string?)
	state.focus = name
	syncFocus(state)
end

-- Clicking something else leaves a search/comment/link field.
local function blurTextFocus(state: BlockState)
	local focus = state.focus
	if focus == "search" or focus == "comment" or focus == "link" then
		setFocus(state, nil)
	end
end

-- ─── Notice ─────────────────────────────────────────────────────────────────

local function setNotice(state: BlockState, run: Run, message: string)
	state.notice = message
	cancelTimer(run.noticeTimer)
	run.noticeTimer = tern.timer(NOTICE_MS, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		live.noticeTimer = nil
		if state.notice == message then
			state.notice = nil
			state.cx:render()
		end
	end)
end

-- The first load is done: the list shows, and a notice held back while it loaded (`readyNotice`) starts now.
local function markReady(state: BlockState, run: Run)
	state.phase = "ready"
	local pending = run.readyNotice
	if pending ~= nil then
		run.readyNotice = nil
		setNotice(state, run, pending)
	end
end

-- ─── Selection and drawer ───────────────────────────────────────────────────

local function dropEditForm(state: BlockState)
	local form = state.form
	if form ~= nil and form.kind == "edit" then
		state.form = nil
		if state.focus == "form" then
			setFocus(state, nil)
		end
	end
end

-- The link input and the inline edit form belong to the open drawer.
local function dropDrawerInputs(state: BlockState, run: Run)
	state.link = nil
	run.editAfterLoad = nil
	dropEditForm(state)
	if state.focus == "comment" or state.focus == "link" then
		setFocus(state, nil)
	end
end

local function supersedeDetail(state: BlockState, run: Run)
	run.detailToken += 1
	cancelTimer(run.detailTimer)
	run.detailTimer = nil
	state.detailLoading = false
end

local function closeDrawer(state: BlockState, run: Run)
	state.drawerOpen = false
	supersedeDetail(state, run)
	dropDrawerInputs(state, run)
end

local function clearSelection(state: BlockState, run: Run)
	closeDrawer(state, run)
	setSelectedId(state, nil)
	state.detail = nil
	text.set(state.comment, "")
end

-- The drawer, its link input and edit form belong to the Issues tab while it is on screen: leaving the tab (another
-- tab, Back, a closed page) closes them. The tab keeps its selection.
function projectIssues.leave(state: BlockState, run: Run)
	if model.issuesTab(state) == nil then
		return
	end
	closeDrawer(state, run)
	if state.focus == "search" then
		setFocus(state, nil)
	end
end

local function clearProjectSelection(state: BlockState)
	state.projects.selectedId = nil
end

-- ─── Errors and setup ───────────────────────────────────────────────────────

local function resetData(state: BlockState, run: Run)
	state.generation += 1
	state.busy = false
	run.fgKind = nil
	state.reloading = false
	run.metaReady = false
	run.reloadQueued = false
	supersedeDetail(state, run)
	run.pageToken += 1
	run.activityToken += 1
	run.issuesToken += 1
	run.issuesInFlight = false
	state.projectPage = nil
	run.editAfterLoad = nil
	state.viewer = nil
	state.teams = {}
	state.issues = {}
	state.truncated = false
	state.fetchedAt = nil
	state.maxUpdatedAt = nil
	local query = state.projects.query
	state.projects = emptyProjects()
	state.projects.query = query
	state.selectedId = nil
	state.detail = nil
	state.drawerOpen = false
	text.set(state.comment, "")
	state.link = nil
	state.form = nil
	state.error = nil
	state.notice = nil
	run.readyNotice = nil
	run.goneProjects = {}
	state.backoffUntil = nil
end

local function enterSetup(state: BlockState, run: Run, message: string?)
	resetData(state, run)
	run.cfg = nil
	state.keySource = nil
	state.phase = "setup"
	state.setupError = message
	text.set(state.setupKey, "")
	setFocus(state, "setup")
end

-- Routes a failed request: auth → setup, rate → backoff, everything else → inline or banner.
-- The banner (`state.error`) alone carries the auth and rate messages: `tick` counts the rate message down, so an
-- inline target never receives it (and keeps what it showed before).
local function fail(state: BlockState, err: ApiError, inline: ((string) -> ())?)
	local run = runOf(state)
	if run == nil then
		return
	end
	if err.kind == "auth" then
		if state.keySource == "env" then
			state.error = "Linear rejected the API key in LINEAR_API_KEY."
		else
			enterSetup(state, run, "Linear rejected the API key.")
		end
		return
	end
	if err.kind == "rate" then
		local waitMs = err.retryAfterMs or DEFAULT_BACKOFF_MS
		state.backoffUntil = nowMs() + waitMs
		state.error = model.rateMessage(waitMs)
		return
	end
	if inline ~= nil then
		inline(err.message)
	else
		state.error = err.message
	end
end

-- ─── Applying results ───────────────────────────────────────────────────────

local function replaceIssue(list: { Issue }, issue: Issue): boolean
	for index, existing in list do
		if existing.id == issue.id then
			list[index] = issue
			return true
		end
	end
	return false
end

-- A mutation's payload may omit the detail-only fields the drawer already has.
local function mergeDetail(old: Issue, fresh: Issue): Issue
	if fresh.detailed then
		return fresh
	end
	local merged = table.clone(fresh)
	merged.description = old.description
	merged.comments = old.comments
	merged.detailed = old.detailed
	return merged
end

-- Applies a mutation's issue to the list on screen (and the drawer's detail).
local function applyIssue(state: BlockState, issue: Issue, insertIfNew: boolean)
	local list = model.issueList(state)
	if not replaceIssue(list, issue) and insertIfNew then
		table.insert(list, 1, issue)
	end
	local detail = state.detail
	if detail ~= nil and detail.id == issue.id then
		state.detail = mergeDetail(detail, issue)
	end
end

local function commitIssues(state: BlockState, run: Run, page: types.IssuePage)
	state.issues = page.issues
	state.truncated = page.truncated
	state.fetchedAt = os.time()
	local newest: string? = nil
	for _, issue in page.issues do
		if newest == nil or issue.updatedAt > newest then
			newest = issue.updatedAt
		end
	end
	state.maxUpdatedAt = newest
	run.lastFullAt = tern.now()
	-- Issues mode's selection; the Issues tab may be on screen when a background reload of issues mode lands.
	local id = state.selectedId
	if id == nil or state.detailLoading then
		return
	end
	for _, issue in state.issues do
		if issue.id == id then
			return
		end
	end
	local detail = state.detail
	if detail ~= nil and detail.id == id then
		return
	end
	if model.issuesTab(state) ~= nil then
		state.selectedId = nil
	else
		clearSelection(state, run)
	end
end

local function newestUpdate(updatedAts: { string }): string?
	local newest: string? = nil
	for _, updatedAt in updatedAts do
		if newest == nil or updatedAt > newest then
			newest = updatedAt
		end
	end
	return newest
end

-- `seq` is the request's `run.projectsSeq`: projects evicted after it started stay out (see `goneProjects`).
local function commitProjects(state: BlockState, run: Run, page: types.ProjectPage, seq: number)
	local projects = state.projects
	local items: { Project } = {}
	for _, project in page.projects do
		local gone = run.goneProjects[project.id]
		if gone == nil or seq > gone then
			table.insert(items, project)
		end
	end
	for id, gone in run.goneProjects do
		if seq > gone then
			run.goneProjects[id] = nil
		end
	end
	projects.items = items
	projects.truncated = page.truncated
	projects.fetchedAt = os.time()
	local updatedAts: { string } = {}
	for _, project in items do
		table.insert(updatedAts, project.updatedAt)
	end
	projects.maxUpdatedAt = newestUpdate(updatedAts)
	run.lastFullAt = tern.now()
	local id = projects.selectedId
	if id ~= nil and findProject(state, id) == nil then
		clearProjectSelection(state)
	end
end

-- ─── Detail loads ───────────────────────────────────────────────────────────
-- Own flag and token; they never touch `busy`.

local openEditForm: (state: BlockState) -> ()

local function fetchDetail(state: BlockState, run: Run)
	local cfg = run.cfg
	local id = model.selectedIssueId(state)
	if cfg == nil or id == nil then
		return
	end
	run.detailToken += 1
	local token = run.detailToken
	linear.issue(cfg, id, function(issue, err)
		local live = liveRun(state)
		if live == nil or live.detailToken ~= token then
			return
		end
		state.detailLoading = false
		if issue ~= nil then
			state.error = nil
			state.detail = issue
			replaceIssue(model.issueList(state), issue)
			if live.editAfterLoad == id then
				live.editAfterLoad = nil
				openEditForm(state)
			end
		else
			live.editAfterLoad = nil
			local failure = err or unknownError()
			if failure.kind == "notfound" and findIssue(state, id) == nil then
				clearSelection(state, live)
			end
			fail(state, failure, nil)
		end
		state.cx:render()
	end)
end

-- Loads the selected issue's detail now, or after `delayMs` (keyboard navigation).
local function requestDetail(state: BlockState, run: Run, delayMs: number)
	cancelTimer(run.detailTimer)
	run.detailTimer = nil
	local id = model.selectedIssueId(state)
	if id == nil then
		return
	end
	local detail = state.detail
	if detail ~= nil and detail.id ~= id then
		state.detail = nil
		detail = nil
	end
	state.detailLoading = true
	run.detailToken += 1
	if delayMs <= 0 then
		fetchDetail(state, run)
		return
	end
	run.detailTimer = tern.timer(delayMs, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		live.detailTimer = nil
		if model.selectedIssueId(state) == id and state.drawerOpen then
			fetchDetail(state, live)
		end
	end)
end

local function selectIssue(state: BlockState, run: Run, id: string, open: boolean, delayMs: number)
	local changed = model.selectedIssueId(state) ~= id
	if changed then
		setSelectedId(state, id)
		text.set(state.comment, "")
		dropDrawerInputs(state, run)
		supersedeDetail(state, run)
		local detail = state.detail
		if detail ~= nil and detail.id ~= id then
			state.detail = nil
		end
	end
	local wasOpen = state.drawerOpen
	if open then
		state.drawerOpen = true
	end
	if state.drawerOpen and (changed or not wasOpen or (state.detail == nil and not state.detailLoading)) then
		requestDetail(state, run, delayMs)
	end
end

-- ─── Background reads ───────────────────────────────────────────────────────

local reloadData: (state: BlockState, run: Run) -> ()

local function runQueuedReload(state: BlockState, run: Run)
	if run.reloadQueued then
		run.reloadQueued = false
		reloadData(state, run)
	end
end

-- One background read: `start` issues the request; `commit` applies a result unless the generation moved on.
local function backgroundRead<T>(
	state: BlockState,
	run: Run,
	start: (types.Config, types.Callback<T>) -> (),
	commit: (T, Run) -> ()
)
	local cfg = run.cfg
	if cfg == nil or state.phase ~= "ready" then
		return
	end
	if state.refreshing then
		run.reloadQueued = true
		return
	end
	state.refreshing = true
	local generation = state.generation
	start(cfg, function(result: T?, err: ApiError?)
		local live = liveRun(state)
		if live == nil then
			return
		end
		state.refreshing = false
		if state.generation == generation then
			if result ~= nil then
				commit(result, live)
				state.error = nil
			elseif err ~= nil then
				fail(state, err, nil)
			end
		end
		state.cx:render()
		runQueuedReload(state, live)
	end)
end

local function reloadIssues(state: BlockState, run: Run)
	backgroundRead(state, run, function(cfg: types.Config, done: types.Callback<types.IssuePage>)
		linear.issues(cfg, model.serverFilter(state.prefs), done)
	end, function(page: types.IssuePage, live: Run)
		commitIssues(state, live, page)
	end)
end

local function reloadProjects(state: BlockState, run: Run)
	local seq = 0
	backgroundRead(state, run, function(cfg: types.Config, done: types.Callback<types.ProjectPage>)
		run.projectsSeq += 1
		seq = run.projectsSeq
		linear.projects(cfg, model.projectServerFilter(state.prefs), done)
	end, function(page: types.ProjectPage, live: Run)
		commitProjects(state, live, page, seq)
	end)
end

-- Background reload of the active mode's list.
reloadData = function(state: BlockState, run: Run)
	if inProjects(state) then
		reloadProjects(state, run)
	else
		reloadIssues(state, run)
	end
end

-- Authoritative reload after a mutation: the list on screen (issues mode's or the Issues tab's), and the drawer if open.
-- A project page's hidden Issues tab (the mutation may have started there) is marked stale: its next show reloads it.
local function reloadAfterMutation(state: BlockState, run: Run)
	local page = state.projectPage
	if model.issuesTab(state) ~= nil then
		projectIssues.fetch(state, run, false)
	elseif page ~= nil then
		page.issues.stale = true
	elseif not inProjects(state) then
		reloadIssues(state, run)
	end
	if state.drawerOpen and model.selectedIssueId(state) ~= nil then
		requestDetail(state, run, 0)
	end
end

-- ─── Foreground requests ────────────────────────────────────────────────────

-- Returns the new generation, or nil when a foreground request already owns `busy`.
-- A load may supersede a load; a mutation never supersedes anything.
local function beginForeground(state: BlockState, run: Run, kind: "load" | "mutation"): number?
	if state.busy and not (kind == "load" and run.fgKind == "load") then
		return nil
	end
	state.busy = true
	state.generation += 1
	run.fgKind = kind
	return state.generation
end

-- Liveness plus "not superseded" check for a foreground completion.
local function current(state: BlockState, generation: number): Run?
	local run = liveRun(state)
	if run ~= nil and state.generation == generation then
		return run
	end
	return nil
end

local function settle(state: BlockState, run: Run)
	state.busy = false
	state.reloading = false
	run.fgKind = nil
end

-- Tern restores a select only when its `value` prop changes, so a pick that was not applied needs a
-- remount (the epoch is part of every select's key) to show the authoritative value again.
local function bumpControls(state: BlockState)
	state.controlEpoch += 1
end

-- A mutation is in flight: form fields must not change under a form that success is about to close.
local function formLocked(state: BlockState, run: Run): boolean
	return state.busy and run.fgKind == "mutation"
end

-- viewer (when unknown) → teams → the active mode's data; `dataOnly` skips straight to the data.
-- Issues mode loads the issues; projects mode loads the organization's project statuses, then the projects.
local function loadAll(state: BlockState, dataOnly: boolean)
	local run = runOf(state)
	if run == nil then
		return
	end
	local cfg = run.cfg
	if cfg == nil then
		return
	end
	local generation = beginForeground(state, run, "load")
	if generation == nil then
		return
	end
	state.reloading = state.phase == "ready"

	local function failed(err: ApiError?)
		local live = current(state, generation)
		if live == nil then
			return
		end
		settle(state, live)
		if state.phase == "loading" then
			markReady(state, live)
		end
		fail(state, err or unknownError(), nil)
		state.cx:render()
	end

	local function loadIssues()
		linear.issues(cfg, model.serverFilter(state.prefs), function(page, err)
			local live = current(state, generation)
			if live == nil then
				return
			end
			if page == nil then
				failed(err)
				return
			end
			settle(state, live)
			commitIssues(state, live, page)
			markReady(state, live)
			state.error = nil
			if state.drawerOpen and state.selectedId ~= nil then
				requestDetail(state, live, 0)
			end
			state.cx:render()
		end)
	end

	local function loadProjects()
		linear.projectStatuses(cfg, function(statuses, statusErr)
			if current(state, generation) == nil then
				return
			end
			if statuses == nil then
				failed(statusErr)
				return
			end
			run.projectsSeq += 1
			local seq = run.projectsSeq
			linear.projects(cfg, model.projectServerFilter(state.prefs), function(page, err)
				local live = current(state, generation)
				if live == nil then
					return
				end
				if page == nil then
					failed(err)
					return
				end
				settle(state, live)
				state.projects.statuses = statuses
				commitProjects(state, live, page, seq)
				markReady(state, live)
				state.error = nil
				state.cx:render()
			end)
		end)
	end

	local function loadData()
		if inProjects(state) then
			loadProjects()
		else
			loadIssues()
		end
	end

	local function loadTeams()
		linear.teams(cfg, function(teams, err)
			if current(state, generation) == nil then
				return
			end
			if teams == nil then
				failed(err)
				return
			end
			state.teams = teams
			run.metaReady = true
			local prefs = state.prefs
			if prefs.scope == "team" and teamById(state, prefs.teamId) == nil then
				prefs.scope = "mine"
				prefs.teamId = nil
			end
			if prefs.projectScope == "team" and teamById(state, prefs.projectTeamId) == nil then
				prefs.projectScope = "all"
				prefs.projectTeamId = nil
			end
			loadData()
		end)
	end

	if dataOnly then
		loadData()
	elseif state.viewer ~= nil then
		loadTeams()
	else
		linear.viewer(cfg, function(viewer, err)
			if current(state, generation) == nil then
				return
			end
			if viewer == nil then
				failed(err)
				return
			end
			state.viewer = viewer
			loadTeams()
		end)
	end
end

-- Runs one foreground mutation. `inline` receives failure text for a dialog or input;
-- without it failures land in the banner.
local function runMutation<T>(
	state: BlockState,
	inline: ((string) -> ())?,
	start: (types.Config, types.Callback<T>, () -> boolean) -> (),
	onSuccess: (T, Run) -> ()
)
	local run = runOf(state)
	if run == nil then
		return
	end
	local cfg = run.cfg
	if cfg == nil then
		return
	end
	local generation = beginForeground(state, run, "mutation")
	if generation == nil then
		return
	end
	-- `start` may chain requests; each hop checks this before it writes anything.
	local function alive(): boolean
		return current(state, generation) ~= nil
	end
	start(cfg, function(result: T?, err: ApiError?)
		local live = current(state, generation)
		if live == nil then
			return
		end
		settle(state, live)
		if result == nil then
			bumpControls(state)
			fail(state, err or unknownError(), inline)
		else
			state.error = nil
			onSuccess(result, live)
		end
		state.cx:render()
	end, alive)
end

-- ─── Polling ────────────────────────────────────────────────────────────────

local function pollAllowed(state: BlockState): boolean
	if state.phase ~= "ready" or state.busy or state.refreshing or state.form ~= nil then
		return false
	end
	local focus = state.focus
	return focus ~= "comment" and focus ~= "form" and focus ~= "link"
end

-- The change check of the active mode; a newer `updatedAt` than the list's newest reloads that list.
local function checkForChanges(state: BlockState, run: Run)
	local cfg = run.cfg
	if cfg == nil then
		return
	end
	local projects = inProjects(state)
	local since = if projects then state.projects.maxUpdatedAt else state.maxUpdatedAt
	local generation = state.generation
	local function onResult(newest: string?, err: ApiError?)
		local live = liveRun(state)
		if live == nil then
			return
		end
		state.refreshing = false
		if state.generation == generation then
			local known = if projects then state.projects.maxUpdatedAt else state.maxUpdatedAt
			if err ~= nil then
				fail(state, err, nil)
			else
				state.error = nil
				-- A check still in flight when the project page opened leaves the list alone: the list's polling
				-- pauses with the page, and the first check after Back finds the same change.
				local paused = projects and state.projectPage ~= nil
				if not paused and newest ~= nil and (known == nil or newest > known) then
					if projects then
						reloadProjects(state, live)
					else
						reloadIssues(state, live)
					end
				end
			end
		end
		state.cx:render()
		runQueuedReload(state, live)
	end
	state.refreshing = true
	if projects then
		linear.projectsChanged(cfg, model.projectServerFilter(state.prefs), since, onResult)
	else
		linear.changedSince(cfg, model.serverFilter(state.prefs), since, onResult)
	end
end

-- ─── Project page ───────────────────────────────────────────────────────────
-- Own token, never `busy`: the page's detail loads like the drawer's. The list underneath stays as it was.

local function closeProjectPage(state: BlockState, run: Run)
	local page = state.projectPage
	if page == nil then
		return
	end
	projectIssues.leave(state, run)
	-- A comment draft typed on the Issues tab belongs to the tab's selection, never to issues mode's: once the tab
	-- selected an issue, issues mode's own draft was already cleared (selectIssue), so the draft is the tab's.
	if page.issues.selectedId ~= nil then
		text.set(state.comment, "")
	end
	run.pageToken += 1
	run.activityToken += 1
	run.issuesToken += 1
	run.issuesInFlight = false
	state.projectPage = nil
	if findProject(state, page.projectId) ~= nil then
		state.projects.selectedId = page.projectId
	end
end

-- The open page's project is gone (`notfound`): it leaves the list and the selection, a list result already in
-- flight cannot bring it back (`goneProjects`), the page closes and the notice says why. During the first load the
-- notice waits for the list (`readyNotice`).
local function projectGone(state: BlockState, run: Run, id: string)
	local kept: { Project } = {}
	for _, project in state.projects.items do
		if project.id ~= id then
			table.insert(kept, project)
		end
	end
	state.projects.items = kept
	run.goneProjects[id] = run.projectsSeq
	if state.projects.selectedId == id then
		clearProjectSelection(state)
	end
	closeProjectPage(state, run)
	if state.phase == "ready" then
		setNotice(state, run, "Project not found")
	else
		run.readyNotice = "Project not found"
	end
end

-- Loads the open page's detail. `shown` marks it loading (open, `r`, Refresh); a poll reload stays silent.
-- `notfound` drops the project (projectGone); other failures show in the page and keep what it had. Success clears
-- only the page's own error: `state.error` belongs to the request that set it (a failed list load stays visible).
local function fetchProjectPage(state: BlockState, run: Run, shown: boolean)
	local page = state.projectPage
	local cfg = run.cfg
	if page == nil or cfg == nil then
		return
	end
	run.pageToken += 1
	local token = run.pageToken
	if shown then
		page.loading = true
	end
	linear.project(cfg, page.projectId, function(detail, err)
		local live = liveRun(state)
		if live == nil or live.pageToken ~= token or state.projectPage ~= page then
			return
		end
		page.loading = false
		if detail ~= nil then
			detail.milestones = model.sortMilestones(detail.milestones)
			page.detail = detail
			page.error = nil
			page.fetchedAt = os.time()
			projectIssues.dropMissingMilestone(state, live, page)
		else
			local failure = err or unknownError()
			if failure.kind == "notfound" then
				projectGone(state, live, page.projectId)
			else
				fail(state, failure, function(message: string)
					page.error = message
				end)
			end
		end
		state.cx:render()
	end)
end

local function openProjectPage(state: BlockState, run: Run, id: string)
	if findProject(state, id) == nil then
		return
	end
	state.projects.selectedId = id
	if state.focus == "search" then
		setFocus(state, nil)
	end
	state.projectPage = newPage(id, "overview")
	fetchProjectPage(state, run, true)
end

-- The Activity tab's requests, on their own token like the detail and never `busy`:
-- "shown" (first show, `r`, Refresh on the tab) marks the tab loading, "poll" reloads silently; both reload the first
-- pages and keep the older pages `Load more` added. "more" fetches the next pages and appends them.
-- `notfound` drops the project like the detail (projectGone); other failures show in the tab and keep what it had.
local function fetchActivity(state: BlockState, run: Run, mode: "shown" | "poll" | "more")
	local page = state.projectPage
	local cfg = run.cfg
	if page == nil or cfg == nil then
		return
	end
	local cursors: types.ActivityCursors? = nil
	if mode == "more" then
		local loaded = page.activity
		cursors = if loaded ~= nil then model.activityCursors(loaded) else nil
		if cursors == nil then
			return
		end
		page.activityPaging = true
	else
		page.activityPaging = false
		if mode == "shown" then
			page.activityLoading = true
		end
	end
	run.activityToken += 1
	local token = run.activityToken
	linear.projectActivity(cfg, page.projectId, cursors, function(result, err)
		local live = liveRun(state)
		if live == nil or live.activityToken ~= token or state.projectPage ~= page then
			return
		end
		page.activityLoading = false
		page.activityPaging = false
		if result ~= nil then
			local loaded = page.activity
			if cursors ~= nil and loaded ~= nil then
				page.activity = model.activityAppended(loaded, result, cursors)
			else
				page.activity = model.activityReloaded(loaded, result)
				page.activityFetchedAt = os.time()
			end
			page.activityError = nil
		else
			local failure = err or unknownError()
			if failure.kind == "notfound" then
				projectGone(state, live, page.projectId)
			else
				fail(state, failure, function(message: string)
					page.activityError = message
				end)
			end
		end
		state.cx:render()
	end)
end

-- ─── Project page: the Issues tab ───────────────────────────────────────────
-- The project's issues (model.projectIssueFilter), kept in `ProjectPageState.issues`, never in issues mode's list.
-- Own token, never `busy`, like the activity; a result for a superseded token or a closed page is dropped.

function projectIssues.commit(state: BlockState, run: Run, tab: types.ProjectIssuesState, result: types.IssuePage)
	tab.items = result.issues
	tab.truncated = result.truncated
	tab.fetchedAt = os.time()
	local updatedAts: { string } = {}
	for _, issue in result.issues do
		table.insert(updatedAts, issue.updatedAt)
	end
	tab.maxUpdatedAt = newestUpdate(updatedAts)
	run.issuesFullAt = tern.now()
	-- Like issues mode, a selection that left the list goes, but only the drawer open over this tab may keep it
	-- (while it shows or loads that issue): a closed drawer's cached detail would leave it selected and actionable.
	local id = tab.selectedId
	if id == nil then
		return
	end
	for _, issue in tab.items do
		if issue.id == id then
			return
		end
	end
	local onScreen = model.issuesTab(state) == tab
	local detail = state.detail
	if onScreen and state.drawerOpen and (state.detailLoading or (detail ~= nil and detail.id == id)) then
		return
	end
	if onScreen then
		clearSelection(state, run)
	else
		tab.selectedId = nil
	end
end

-- The tab's server filter changed (view): the old filter's rows, watermark and selection go (the drawer open over
-- the tab keeps its issue) and the new filter loads like a first load, so no key acts on rows of the old filter and a
-- failed load leaves nothing to poll with the old watermark.
function projectIssues.refilter(state: BlockState, run: Run, tab: types.ProjectIssuesState)
	tab.items = {}
	tab.truncated = false
	tab.fetchedAt = nil
	tab.maxUpdatedAt = nil
	tab.error = nil
	if not state.drawerOpen then
		tab.selectedId = nil
	end
	projectIssues.fetch(state, run, true)
end

-- A full load of the open page's Issues tab. `shown` (first show, view change, `r`, Refresh) shows the loading row;
-- poll, post-mutation and stale reloads stay silent. Failures show in the tab, keep what it had and leave it stale.
function projectIssues.fetch(state: BlockState, run: Run, shown: boolean)
	local page = state.projectPage
	local cfg = run.cfg
	if page == nil or cfg == nil then
		return
	end
	local tab = page.issues
	tab.stale = false
	run.issuesToken += 1
	local token = run.issuesToken
	run.issuesInFlight = true
	if shown then
		tab.loading = true
	end
	local filter = model.projectIssueFilter(page.projectId, tab.view, tab.milestoneId)
	linear.issues(cfg, filter, function(result, err)
		local live = liveRun(state)
		if live == nil or live.issuesToken ~= token or state.projectPage ~= page then
			return
		end
		live.issuesInFlight = false
		tab.loading = false
		if result ~= nil then
			projectIssues.commit(state, live, tab, result)
			tab.error = nil
		else
			tab.stale = true
			fail(state, err or unknownError(), function(message: string)
				tab.error = message
			end)
		end
		state.cx:render()
	end)
end

-- The tab's change check (IssuesChanged under its filter): something newer than its newest issue reloads it, or
-- marks it stale when the tab is no longer on screen. A successful check clears a failed check's error (checks run
-- only while the last full load succeeded: a failed one leaves the tab stale).
function projectIssues.check(state: BlockState, run: Run)
	local page = state.projectPage
	local cfg = run.cfg
	if page == nil or cfg == nil then
		return
	end
	local tab = page.issues
	run.issuesToken += 1
	local token = run.issuesToken
	run.issuesInFlight = true
	local filter = model.projectIssueFilter(page.projectId, tab.view, tab.milestoneId)
	linear.changedSince(cfg, filter, tab.maxUpdatedAt, function(newest, err)
		local live = liveRun(state)
		if live == nil or live.issuesToken ~= token or state.projectPage ~= page then
			return
		end
		live.issuesInFlight = false
		if err ~= nil then
			fail(state, err, function(message: string)
				tab.error = message
			end)
		else
			tab.error = nil
			local known = tab.maxUpdatedAt
			if newest ~= nil and (known == nil or newest > known) then
				if model.issuesTab(state) == tab then
					projectIssues.fetch(state, live, false)
				else
					tab.stale = true
				end
			end
		end
		state.cx:render()
	end)
end

-- Shows a tab; the Activity and Issues tabs load the first time they are shown (and after a failed first load); a stale
-- Issues tab reloads silently. Leaving the Issues tab closes its drawer.
local function selectProjectTab(state: BlockState, run: Run, tab: types.ProjectTab?)
	local page = state.projectPage
	if page == nil or tab == nil then
		return
	end
	if tab ~= page.tab then
		projectIssues.leave(state, run)
	end
	page.tab = tab
	if tab == "activity" and page.activity == nil and not page.activityLoading then
		fetchActivity(state, run, "shown")
	elseif tab == "issues" and (page.issues.stale or (page.issues.fetchedAt == nil and not page.issues.loading)) then
		projectIssues.fetch(state, run, page.issues.fetchedAt == nil)
	end
end

-- The milestone filter of the Issues tab (a milestone row of the Overview, the tab's milestone select): one of the
-- page's milestones, or nil for all. Shows the Issues tab; a changed filter reloads it as a shown load.
function projectIssues.showMilestone(state: BlockState, run: Run, id: string?)
	local page = state.projectPage
	if page == nil then
		return
	end
	local detail = page.detail
	if id ~= nil and (detail == nil or model.milestoneById(detail.milestones, id) == nil) then
		return
	end
	local tab = page.issues
	local changed = tab.milestoneId ~= id
	tab.milestoneId = id
	-- Showing a tab that never loaded loads it, already with the new filter.
	local firstShow = tab.fetchedAt == nil and not tab.loading
	selectProjectTab(state, run, "issues")
	if changed and not firstShow then
		projectIssues.fetch(state, run, true)
	end
end

-- After a detail load: a milestone filter whose milestone the project no longer has (deleted since it was saved or
-- picked) is dropped with a notice; the tab reloads unfiltered on screen, or on its next show.
function projectIssues.dropMissingMilestone(state: BlockState, run: Run, page: types.ProjectPageState)
	local tab = page.issues
	local detail = page.detail
	if tab.milestoneId == nil or detail == nil or model.milestoneById(detail.milestones, tab.milestoneId) ~= nil then
		return
	end
	tab.milestoneId = nil
	setNotice(state, run, "Milestone not found; showing all issues")
	if page.tab == "issues" then
		projectIssues.fetch(state, run, true)
	else
		run.issuesToken += 1
		run.issuesInFlight = false
		tab.loading = false
		tab.fetchedAt = nil
	end
end

-- `r` / Refresh on the page: reloads the tab on screen (on the Issues tab, also the open drawer's issue).
local function refreshProjectTab(state: BlockState, run: Run)
	local page = state.projectPage
	if page == nil then
		return
	end
	if page.tab == "activity" then
		fetchActivity(state, run, "shown")
	elseif page.tab == "issues" then
		projectIssues.fetch(state, run, true)
		if state.drawerOpen and model.selectedIssueId(state) ~= nil then
			requestDetail(state, run, 0)
		end
	else
		fetchProjectPage(state, run, true)
	end
end

-- The poll tick on the Issues tab: a full reload before the first load, when stale and every FULL_RELOAD_MS, else the
-- change check; the open drawer's issue reloads beside it.
function projectIssues.poll(state: BlockState, run: Run, page: types.ProjectPageState)
	local tab = page.issues
	if not run.issuesInFlight then
		if tab.fetchedAt == nil or tab.stale or tern.now() - run.issuesFullAt >= FULL_RELOAD_MS then
			projectIssues.fetch(state, run, false)
		else
			projectIssues.check(state, run)
		end
	end
	if state.drawerOpen and tab.selectedId ~= nil and not state.detailLoading then
		requestDetail(state, run, 0)
	end
end

local function tick(state: BlockState, run: Run)
	if run.cfg == nil then
		return
	end
	local backoff = state.backoffUntil
	if backoff ~= nil then
		local remaining = backoff - nowMs()
		if remaining > 0 then
			if model.isRateMessage(state.error) then
				state.error = model.rateMessage(remaining)
				state.cx:render()
			end
			return
		end
		state.backoffUntil = nil
		if model.isRateMessage(state.error) then
			state.error = nil
			state.cx:render()
		end
	end
	if not pollAllowed(state) then
		return
	end
	if not run.metaReady or (inProjects(state) and #state.projects.statuses == 0) then
		loadAll(state, run.metaReady)
		state.cx:render()
		return
	end
	-- While the project page is open the list's polling pauses; the page's detail reloads on the same tick, and the
	-- activity or the Issues tab's list (and its drawer) too while their tab is shown.
	local page = if inProjects(state) then state.projectPage else nil
	if page ~= nil then
		if not page.loading then
			fetchProjectPage(state, run, false)
		end
		if page.tab == "activity" and not page.activityLoading and not page.activityPaging then
			fetchActivity(state, run, "poll")
		elseif page.tab == "issues" then
			projectIssues.poll(state, run, page)
		end
		return
	end
	if tern.now() - run.lastFullAt >= FULL_RELOAD_MS then
		reloadData(state, run)
	else
		checkForChanges(state, run)
	end
	if state.drawerOpen and model.selectedIssueId(state) ~= nil and not state.detailLoading then
		requestDetail(state, run, 0)
	end
end

-- A re-armed one-shot timer; it ends with the block's pane.
local function schedulePoll(state: BlockState, run: Run)
	run.poll = tern.timer(POLL_MS, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		schedulePoll(state, live)
		tick(state, live)
	end)
end

-- ─── Issue mutations ────────────────────────────────────────────────────────

local function updateIssue(state: BlockState, issue: Issue, patch: Patch, describe: (Issue) -> string)
	runMutation(state, nil, function(cfg: types.Config, done: types.Callback<Issue>)
		linear.updateIssue(cfg, issue.id, patch, done)
	end, function(updated: Issue, run: Run)
		applyIssue(state, updated, false)
		setNotice(state, run, describe(updated))
		reloadAfterMutation(state, run)
	end)
end

local function describeAssignee(state: BlockState, updated: Issue): string
	local assignee = updated.assignee
	if assignee == nil then
		return "Unassigned"
	end
	if assignee.id == viewerId(state) then
		return "Assigned to you"
	end
	return "Assigned to " .. assignee.displayName
end

local function moveToState(state: BlockState, issue: Issue, target: types.WorkflowState?, missing: string)
	if target == nil then
		state.error = missing
		return
	end
	if target.id == issue.state.id then
		return
	end
	updateIssue(state, issue, { stateId = target.id }, function(updated)
		return "Moved to " .. updated.state.name
	end)
end

local function issueTeam(state: BlockState, issue: Issue): Team?
	local team = teamById(state, issue.teamId)
	if team == nil then
		state.error = "Team " .. issue.teamKey .. " is not available."
	end
	return team
end

local function closeIssue(state: BlockState, issue: Issue)
	local team = issueTeam(state, issue)
	if team ~= nil then
		moveToState(state, issue, model.doneState(team), "Team " .. team.key .. " has no Done state.")
	end
end

local function reopenIssue(state: BlockState, issue: Issue)
	local team = issueTeam(state, issue)
	if team ~= nil then
		moveToState(state, issue, model.todoState(team), "Team " .. team.key .. " has no Todo state.")
	end
end

local function toggleClosed(state: BlockState, issue: Issue)
	if model.isClosedType(issue.state.type) then
		reopenIssue(state, issue)
	else
		closeIssue(state, issue)
	end
end

-- `[` / `]`: the previous/next column's state. Issues mode steps through the board's columns (model.adjacentState);
-- the Issues tab's board has one column per state type, so it steps by type within the issue's own team.
local function moveAdjacent(state: BlockState, run: Run, issue: Issue, delta: number)
	local team = issueTeam(state, issue)
	if team == nil then
		return
	end
	local tab = model.issuesTab(state)
	local target = if tab ~= nil
		then model.adjacentTypeState(team, issue, delta, tab.view)
		else model.adjacentState(team, issue, delta, state.prefs.view)
	if target == nil then
		setNotice(state, run, if delta < 0 then "Already in the first column" else "Already in the last column")
		return
	end
	moveToState(state, issue, target, "")
end

local function setAssignee(state: BlockState, issue: Issue, userId: string?)
	local assignee: any = if userId == nil then tern.json.null else userId
	updateIssue(state, issue, { assigneeId = assignee }, function(updated)
		return describeAssignee(state, updated)
	end)
end

local function toggleAssignMe(state: BlockState, issue: Issue)
	local me = viewerId(state)
	if me == nil then
		return
	end
	local assignee = issue.assignee
	if assignee ~= nil and assignee.id == me then
		setAssignee(state, issue, nil)
	else
		setAssignee(state, issue, me)
	end
end

local function setPriority(state: BlockState, issue: Issue, priority: number)
	if priority == issue.priority then
		return
	end
	updateIssue(state, issue, { priority = priority }, function(updated)
		return "Priority: " .. updated.priorityLabel
	end)
end

local function submitComment(state: BlockState)
	local id = model.selectedIssueId(state)
	local body = text.trimmed(state.comment)
	if id == nil or body == "" then
		return
	end
	runMutation(state, nil, function(cfg: types.Config, done: types.Callback<types.Comment>)
		linear.createComment(cfg, id, body, done)
	end, function(comment: types.Comment, run: Run)
		if model.selectedIssueId(state) == id then
			if text.trimmed(state.comment) == body then
				text.set(state.comment, "")
			end
			local detail = state.detail
			if detail ~= nil and detail.id == id then
				local comments: { types.Comment } = detail.comments or {}
				local replaced = false
				for index, existing in comments do
					if existing.id == comment.id then
						comments[index] = comment
						replaced = true
						break
					end
				end
				if not replaced then
					table.insert(comments, comment)
				end
				detail.comments = comments
			end
		end
		setNotice(state, run, "Comment added")
		reloadAfterMutation(state, run)
	end)
end

-- ─── Relations ──────────────────────────────────────────────────────────────

local function openLink(state: BlockState, mode: "blocked-by" | "blocks" | "related")
	if model.selectedIssueId(state) == nil or not state.drawerOpen then
		return
	end
	state.link = { mode = mode, field = text.new(""), error = nil }
	setFocus(state, "link")
end

local function cancelLink(state: BlockState)
	state.link = nil
	if state.focus == "link" then
		setFocus(state, nil)
	end
end

local function submitLink(state: BlockState)
	local link = state.link
	local selectedId = model.selectedIssueId(state)
	if link == nil or selectedId == nil then
		return
	end
	local teamKey, number = model.parseIdentifier(link.field.text)
	if teamKey == nil or number == nil then
		link.error = "Enter an issue identifier like ENG-123."
		return
	end
	local identifier = string.format("%s-%d", teamKey, number)
	link.error = nil
	local mode = link.mode
	runMutation(state, function(message: string)
		link.error = message
	end, function(cfg: types.Config, done: types.Callback<boolean>, alive: () -> boolean)
		linear.lookup(cfg, identifier, function(ref, err)
			if not alive() then
				return
			end
			if err ~= nil then
				done(nil, err)
				return
			end
			if ref == nil then
				done(nil, { kind = "notfound", message = "No issue " .. identifier })
				return
			end
			if ref.id == selectedId then
				done(nil, { kind = "input", message = "An issue can't be linked to itself." })
				return
			end
			if mode == "blocked-by" then
				linear.createRelation(cfg, ref.id, selectedId, "blocks", done)
			elseif mode == "blocks" then
				linear.createRelation(cfg, selectedId, ref.id, "blocks", done)
			else
				linear.createRelation(cfg, selectedId, ref.id, "related", done)
			end
		end)
	end, function(_: boolean, run: Run)
		if state.link == link then
			cancelLink(state)
		end
		setNotice(state, run, "Linked " .. identifier)
		reloadAfterMutation(state, run)
	end)
end

local function unlink(state: BlockState, relationId: string)
	runMutation(state, nil, function(cfg: types.Config, done: types.Callback<boolean>)
		linear.deleteRelation(cfg, relationId, done)
	end, function(_: boolean, run: Run)
		setNotice(state, run, "Relation removed")
		reloadAfterMutation(state, run)
	end)
end

-- ─── Credentials ────────────────────────────────────────────────────────────

local function saveKey(state: BlockState)
	local run = runOf(state)
	if run == nil then
		return
	end
	local key = text.trimmed(state.setupKey)
	if not credentials.looksLikeKey(key) then
		state.setupError = "That doesn't look like a Linear API key."
		return
	end
	local endpoint, rejected = credentials.endpoint()
	if endpoint == nil then
		state.setupError = rejected or "LINEAR_API_URL is not an allowed endpoint."
		state.cx:render()
		return
	end
	local generation = beginForeground(state, run, "mutation")
	if generation == nil then
		return
	end
	state.setupError = nil
	local cfg: types.Config = { key = key, endpoint = endpoint }
	linear.viewer(cfg, function(viewer, err)
		local live = current(state, generation)
		if live == nil then
			return
		end
		if viewer == nil then
			settle(state, live)
			if err ~= nil and err.kind == "auth" then
				state.setupError = "Linear rejected the API key."
			else
				state.setupError = if err ~= nil then err.message else "Could not reach Linear."
			end
			state.cx:render()
			return
		end
		-- The foreground request stays alive until the key is on disk.
		credentials.save(key, function(ok: boolean, reason: string?)
			local saving = current(state, generation)
			if saving == nil then
				return
			end
			settle(state, saving)
			if not ok then
				state.setupError = reason or "Could not store the API key."
				state.cx:render()
				return
			end
			saving.cfg = cfg
			state.keySource = "file"
			state.viewer = viewer
			text.set(state.setupKey, "")
			state.phase = "loading"
			setFocus(state, nil)
			loadAll(state, false)
			state.cx:render()
		end)
	end)
end

local function signOut(state: BlockState, run: Run)
	if state.keySource ~= "file" then
		return
	end
	local cleared, reason = credentials.clear()
	if not cleared then
		-- The key is still on disk: stay signed in and say why.
		state.error = reason or "Could not remove the stored API key."
		return
	end
	enterSetup(state, run, nil)
end

-- ─── Forms ──────────────────────────────────────────────────────────────────

local function textField(
	name: string,
	label: string,
	kind: "text" | "multiline",
	value: string,
	placeholder: string?
): FormField
	return {
		name = name,
		label = label,
		kind = kind,
		field = text.new(value),
		baseline = value,
		placeholder = placeholder,
	}
end

local function choiceField(name: string, label: string, options: { FormOption }, value: string): FormField
	return { name = name, label = label, kind = "choice", value = value, options = options, baseline = value }
end

local function fieldNamed(form: Form, name: string): FormField?
	for _, field in form.fields do
		if field.name == name then
			return field
		end
	end
	return nil
end

local function formText(form: Form, name: string): string
	local field = fieldNamed(form, name)
	if field == nil or field.field == nil then
		return ""
	end
	return text.trimmed(field.field)
end

local function formChoice(form: Form, name: string): string
	local field = fieldNamed(form, name)
	if field == nil then
		return ""
	end
	return field.value or ""
end

local function hasOption(options: { FormOption }, value: string): boolean
	for _, option in options do
		if option.value == value then
			return true
		end
	end
	return false
end

local function priorityOptions(): { FormOption }
	local options: { FormOption } = {}
	for _, priority in model.PRIORITIES do
		table.insert(options, { value = tostring(priority.value), label = priority.label })
	end
	return options
end

local function teamOptions(state: BlockState): { FormOption }
	local options: { FormOption } = {}
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = team.name })
	end
	return options
end

-- `present` keeps an issue's current state selectable even if the team list lacks it.
local function stateOptions(team: Team?, present: types.WorkflowState?): { FormOption }
	local options: { FormOption } = {}
	if team ~= nil then
		for _, workflowState in team.states do
			table.insert(options, { value = workflowState.id, label = workflowState.name })
		end
	end
	if present ~= nil and not hasOption(options, present.id) then
		table.insert(options, { value = present.id, label = present.name })
	end
	return options
end

local function assigneeOptions(team: Team?, current: types.User?): { FormOption }
	local options: { FormOption } = { { value = "", label = "Unassigned" } }
	if team ~= nil then
		for _, member in team.members do
			table.insert(options, { value = member.id, label = member.displayName })
		end
	end
	if current ~= nil and not hasOption(options, current.id) then
		table.insert(options, { value = current.id, label = current.displayName })
	end
	return options
end

local function defaultStateId(team: Team): string
	local todo = model.todoState(team)
	if todo ~= nil then
		return todo.id
	end
	if team.defaultStateId ~= nil then
		return team.defaultStateId
	end
	local first = team.states[1]
	return if first ~= nil then first.id else ""
end

local function defaultAssigneeId(state: BlockState, options: { FormOption }): string
	local me = viewerId(state)
	if state.prefs.scope == "mine" and me ~= nil and hasOption(options, me) then
		return me
	end
	return ""
end

local function createTeam(state: BlockState, form: Form): Team?
	local field = fieldNamed(form, "team")
	if field ~= nil then
		return teamById(state, field.value)
	end
	return state.teams[1]
end

-- (Re)points the create form's state and assignee choices at `team`.
local function configureTeamFields(state: BlockState, form: Form, team: Team)
	local stateField = fieldNamed(form, "state")
	if stateField ~= nil then
		stateField.options = stateOptions(team, nil)
		stateField.value = defaultStateId(team)
		stateField.baseline = stateField.value or ""
	end
	local assigneeField = fieldNamed(form, "assignee")
	if assigneeField ~= nil then
		local options = assigneeOptions(team, nil)
		assigneeField.options = options
		local kept = assigneeField.value
		if kept == nil or kept == "" or not hasOption(options, kept) then
			assigneeField.value = defaultAssigneeId(state, options)
		end
		assigneeField.baseline = assigneeField.value or ""
	end
end

local function openCreate(state: BlockState)
	if state.form ~= nil then
		return
	end
	local team = scopeTeam(state) or state.teams[1]
	if team == nil then
		state.error = "No Linear teams are available."
		return
	end
	local fields: { FormField } = {
		textField("title", "Title", "text", "", "Issue title"),
		textField("description", "Description", "multiline", "", "Add a description…"),
	}
	if #state.teams > 1 then
		table.insert(fields, choiceField("team", "Team", teamOptions(state), team.id))
	end
	table.insert(fields, choiceField("state", "State", {}, ""))
	table.insert(fields, choiceField("priority", "Priority", priorityOptions(), "0"))
	table.insert(fields, choiceField("assignee", "Assignee", {}, ""))
	local form: Form = { kind = "create", issueId = nil, fields = fields, focus = 1, error = nil }
	configureTeamFields(state, form, team)
	state.form = form
	setFocus(state, "form")
end

openEditForm = function(state: BlockState)
	local detail = state.detail
	if state.form ~= nil or detail == nil or detail.id ~= model.selectedIssueId(state) then
		return
	end
	local team = teamById(state, detail.teamId)
	local description = detail.description or ""
	local assignee = detail.assignee
	local fields: { FormField } = {
		textField("title", "Title", "text", detail.title, nil),
		textField("description", "Description", "multiline", description, "Add a description…"),
		choiceField("priority", "Priority", priorityOptions(), tostring(detail.priority)),
		choiceField("state", "State", stateOptions(team, detail.state), detail.state.id),
		choiceField(
			"assignee",
			"Assignee",
			assigneeOptions(team, assignee),
			if assignee ~= nil then assignee.id else ""
		),
	}
	state.form = { kind = "edit", issueId = detail.id, fields = fields, focus = 1, error = nil }
	setFocus(state, "form")
end

-- `e`/`edit`: the form needs the full issue, so wait for the detail when it is missing.
local function beginEdit(state: BlockState, run: Run)
	local id = model.selectedIssueId(state)
	if id == nil or state.form ~= nil then
		return
	end
	local issue = selectedIssue(state)
	if issue == nil then
		return
	end
	local wasOpen = state.drawerOpen
	state.drawerOpen = true
	local detail = state.detail
	if detail ~= nil and detail.id == id then
		openEditForm(state)
		return
	end
	run.editAfterLoad = id
	setNotice(state, run, "Loading issue…")
	if not wasOpen or not state.detailLoading then
		requestDetail(state, run, 0)
	end
end

local function closeForm(state: BlockState)
	state.form = nil
	if state.focus == "form" then
		setFocus(state, nil)
	end
end

local function cancelForm(state: BlockState, run: Run)
	run.editAfterLoad = nil
	closeForm(state)
end

local EDIT_PATCH_KEYS: { [string]: string } = {
	title = "title",
	description = "description",
	priority = "priority",
	state = "stateId",
	assignee = "assigneeId",
}

local function editPatch(form: Form): Patch
	local diff = model.formDiff(form)
	local title = formText(form, "title")
	local titleField = fieldNamed(form, "title")
	local titleUnchanged = titleField ~= nil and title == titleField.baseline
	local patch: Patch = {}
	for name, value in diff do
		local key = EDIT_PATCH_KEYS[name]
		if key == nil or (name == "title" and titleUnchanged) then
			continue
		end
		if name == "title" then
			patch[key] = title
		elseif name == "priority" then
			patch[key] = tonumber(value) or 0
		elseif name == "assignee" and value == "" then
			patch[key] = tern.json.null
		else
			patch[key] = value
		end
	end
	return patch
end

local function submitEdit(state: BlockState, form: Form)
	local issueId = form.issueId
	if issueId == nil then
		return
	end
	if formText(form, "title") == "" then
		form.error = "Title is required."
		return
	end
	local patch = editPatch(form)
	if next(patch) == nil then
		closeForm(state)
		return
	end
	form.error = nil
	runMutation(state, function(message: string)
		form.error = message
	end, function(cfg: types.Config, done: types.Callback<Issue>)
		linear.updateIssue(cfg, issueId, patch, done)
	end, function(updated: Issue, run: Run)
		applyIssue(state, updated, false)
		if state.form == form then
			closeForm(state)
		end
		setNotice(state, run, "Saved " .. updated.identifier)
		reloadAfterMutation(state, run)
	end)
end

local function submitCreate(state: BlockState, form: Form)
	local title = formText(form, "title")
	if title == "" then
		form.error = "Title is required."
		return
	end
	local team = createTeam(state, form)
	if team == nil then
		form.error = "Choose a team."
		return
	end
	local input: types.IssueCreateInput = { teamId = team.id, title = title }
	local description = formText(form, "description")
	if description ~= "" then
		input.description = description
	end
	local priority = tonumber(formChoice(form, "priority")) or 0
	if priority > 0 then
		input.priority = priority
	end
	local assigneeId = formChoice(form, "assignee")
	if assigneeId ~= "" then
		input.assigneeId = assigneeId
	end
	local stateId = formChoice(form, "state")
	if stateId ~= "" then
		input.stateId = stateId
	end
	form.error = nil
	runMutation(state, function(message: string)
		form.error = message
	end, function(cfg: types.Config, done: types.Callback<Issue>)
		linear.createIssue(cfg, input, done)
	end, function(created: Issue, run: Run)
		applyIssue(state, created, true)
		if state.form == form then
			closeForm(state)
		end
		setNotice(state, run, "Created " .. created.identifier)
		reloadAfterMutation(state, run)
	end)
end

local function submitForm(state: BlockState)
	local form = state.form
	local run = runOf(state)
	if form == nil or run == nil or formLocked(state, run) then
		return
	end
	if form.kind == "create" then
		submitCreate(state, form)
	else
		submitEdit(state, form)
	end
end

local function setChoice(state: BlockState, form: Form, field: FormField, value: string)
	field.value = value
	if form.kind == "create" and field.name == "team" then
		local team = teamById(state, value)
		if team ~= nil then
			configureTeamFields(state, form, team)
		end
	end
end

local function stepChoice(state: BlockState, form: Form, field: FormField, delta: number)
	local options = field.options
	if options == nil or #options == 0 then
		return
	end
	local index = 1
	for position, option in options do
		if option.value == field.value then
			index = position
			break
		end
	end
	local target = options[math.clamp(index + delta, 1, #options)]
	setChoice(state, form, field, target.value)
end

local function moveFormFocus(state: BlockState, form: Form, delta: number)
	form.focus = (form.focus - 1 + delta) % #form.fields + 1
	setFocus(state, "form")
end

-- ─── Navigation and filters ─────────────────────────────────────────────────

-- The list on screen after its client filters: issues mode's (Prefs) or the Issues tab's.
local function visibleIssues(state: BlockState): { Issue }
	local tab = model.issuesTab(state)
	if tab ~= nil then
		return model.visible(tab.items, tab, tab.query.text, viewerId(state))
	end
	return model.visible(state.issues, state.prefs, state.query.text, viewerId(state))
end

-- The board columns on screen: issues mode's (team states or state types) or the Issues tab's (state types).
local function issueColumns(state: BlockState, visible: { Issue }): { model.Column }
	local tab = model.issuesTab(state)
	if tab ~= nil then
		return model.typeColumns(visible, tab.view)
	end
	return model.columns(visible, state.prefs, scopeTeam(state))
end

-- The order the active layout renders issues in.
local function orderedIssues(state: BlockState): { Issue }
	local visible = visibleIssues(state)
	if state.prefs.layout == "table" then
		local tab = model.issuesTab(state)
		if tab ~= nil then
			return model.sortTable(visible, tab.sort, tab.sortAsc)
		end
		return model.sortTable(visible, state.prefs.sort, state.prefs.sortAsc)
	end
	-- Board: the cards' order, column by column (type columns re-sort each column by priority).
	local ordered: { Issue } = {}
	for _, column in issueColumns(state, visible) do
		for _, issue in column.issues do
			table.insert(ordered, issue)
		end
	end
	return ordered
end

local function moveSelection(state: BlockState, run: Run, delta: number): boolean
	local ids: { string } = {}
	for _, issue in orderedIssues(state) do
		table.insert(ids, issue.id)
	end
	local selected = model.selectedIssueId(state)
	local target = model.steppedId(ids, selected, delta)
	if target == nil then
		return false
	end
	if target ~= selected then
		selectIssue(state, run, target, false, DETAIL_DEBOUNCE_MS)
	end
	return true
end

-- Board only: first issue of the previous/next non-empty column.
local function moveColumn(state: BlockState, run: Run, delta: number): boolean
	if state.prefs.layout ~= "board" then
		return false
	end
	local columns: { { string } } = {}
	for _, column in issueColumns(state, visibleIssues(state)) do
		local ids: { string } = {}
		for _, issue in column.issues do
			table.insert(ids, issue.id)
		end
		table.insert(columns, ids)
	end
	local target = model.adjacentColumnId(columns, model.selectedIssueId(state), delta)
	if target == nil then
		return false
	end
	selectIssue(state, run, target, false, DETAIL_DEBOUNCE_MS)
	return true
end

-- ─── Projects navigation ────────────────────────────────────────────────────

local function visibleProjects(state: BlockState): { Project }
	return model.visibleProjects(state.projects.items, state.prefs, state.projects.query.text, viewerId(state))
end

local function projectBoardColumns(state: BlockState): { model.ProjectColumn }
	return model.projectColumns(visibleProjects(state), state.prefs, state.projects.statuses)
end

-- The order the active layout renders projects in.
local function orderedProjects(state: BlockState): { Project }
	local prefs = state.prefs
	if prefs.layout == "table" then
		return model.sortProjects(visibleProjects(state), prefs.projectSort, prefs.projectSortAsc)
	end
	local ordered: { Project } = {}
	for _, column in projectBoardColumns(state) do
		for _, project in column.projects do
			table.insert(ordered, project)
		end
	end
	return ordered
end

-- Selecting a project opens nothing: opening a project page is a separate action.
local function selectProject(state: BlockState, id: string)
	if findProject(state, id) ~= nil then
		state.projects.selectedId = id
	end
end

local function moveProjectSelection(state: BlockState, _run: Run, delta: number): boolean
	local ids: { string } = {}
	for _, project in orderedProjects(state) do
		table.insert(ids, project.id)
	end
	local target = model.steppedId(ids, state.projects.selectedId, delta)
	if target == nil then
		return false
	end
	selectProject(state, target)
	return true
end

local function moveProjectColumn(state: BlockState, _run: Run, delta: number): boolean
	if state.prefs.layout ~= "board" then
		return false
	end
	local columns: { { string } } = {}
	for _, column in projectBoardColumns(state) do
		local ids: { string } = {}
		for _, project in column.projects do
			table.insert(ids, project.id)
		end
		table.insert(columns, ids)
	end
	local target = model.adjacentColumnId(columns, state.projects.selectedId, delta)
	if target == nil then
		return false
	end
	selectProject(state, target)
	return true
end

-- Client-side filters keyed to a team no longer apply after a scope change.
local function resetScopedFilters(prefs: Prefs)
	prefs.labelId = nil
	if prefs.assignee ~= nil and prefs.assignee ~= "me" and prefs.assignee ~= "none" then
		prefs.assignee = nil
	end
end

-- True when a change to the server filter may start a foreground reload right now.
local function canReload(state: BlockState, run: Run): boolean
	if run.cfg == nil or state.phase ~= "ready" then
		return false
	end
	return not state.busy or run.fgKind == "load"
end

-- Reloads the active mode's list in the foreground after its server filter changed.
local function reloadBoard(state: BlockState, run: Run, clearBoard: boolean)
	if clearBoard then
		if inProjects(state) then
			clearProjectSelection(state)
			state.projects.items = {}
			state.projects.truncated = false
			state.projects.maxUpdatedAt = nil
		else
			clearSelection(state, run)
			state.issues = {}
			state.truncated = false
			state.maxUpdatedAt = nil
			resetScopedFilters(state.prefs)
		end
	end
	loadAll(state, true)
end

local function setView(state: BlockState, run: Run, value: any)
	local parsed: ("active" | "backlog" | "all")? = parse.view(value)
	-- The Issues tab's view is its own server filter: a shown reload of the tab, never `busy`.
	local tab = model.issuesTab(state)
	if tab ~= nil then
		if parsed ~= nil and parsed ~= tab.view then
			tab.view = parsed
			projectIssues.refilter(state, run, tab)
		end
		return
	end
	local prefs = state.prefs
	local currentView = if inProjects(state) then prefs.projectView else prefs.view
	if parsed == nil or parsed == currentView or not canReload(state, run) then
		return
	end
	if inProjects(state) then
		prefs.projectView = parsed
	else
		prefs.view = parsed
	end
	reloadBoard(state, run, false)
end

local function setLayout(state: BlockState, value: any)
	local parsed: ("board" | "table")? = parse.layout(value)
	if parsed ~= nil then
		state.prefs.layout = parsed
	end
end

local function setMine(state: BlockState, run: Run)
	if state.prefs.scope == "mine" or not canReload(state, run) then
		return
	end
	state.prefs.scope = "mine"
	reloadBoard(state, run, true)
end

local function setTeam(state: BlockState, run: Run, teamId: string)
	local alreadyThere = state.prefs.scope == "team" and state.prefs.teamId == teamId
	if teamById(state, teamId) == nil or alreadyThere or not canReload(state, run) then
		return
	end
	state.prefs.scope = "team"
	state.prefs.teamId = teamId
	reloadBoard(state, run, true)
end

local function nextTeam(state: BlockState, run: Run): boolean
	local teams = state.teams
	if #teams == 0 then
		return false
	end
	local index = 0
	if state.prefs.scope == "team" then
		for position, team in teams do
			if team.id == state.prefs.teamId then
				index = position
				break
			end
		end
	end
	setTeam(state, run, teams[index % #teams + 1].id)
	return true
end

-- Projects mode scope: "all", "mine", or "team" with `teamId`.
local function setProjectScope(state: BlockState, run: Run, scope: "all" | "mine" | "team", teamId: string?)
	local prefs = state.prefs
	if scope == "team" and teamById(state, teamId) == nil then
		return
	end
	local target = if scope == "team" then teamId else nil
	if (prefs.projectScope == scope and prefs.projectTeamId == target) or not canReload(state, run) then
		return
	end
	prefs.projectScope = scope
	prefs.projectTeamId = target
	reloadBoard(state, run, true)
end

local function nextProjectTeam(state: BlockState, run: Run): boolean
	local teams = state.teams
	if #teams == 0 then
		return false
	end
	local index = 0
	if state.prefs.projectScope == "team" then
		for position, team in teams do
			if team.id == state.prefs.projectTeamId then
				index = position
				break
			end
		end
	end
	setProjectScope(state, run, "team", teams[index % #teams + 1].id)
	return true
end

-- The table sort on screen: the Issues tab's, projects mode's or issues mode's.
local function setSort(state: BlockState, key: string)
	local prefs = state.prefs
	local tab = model.issuesTab(state)
	if tab ~= nil then
		if SORT_KEYS[key] then
			tab.sort, tab.sortAsc = model.nextSort(tab.sort, tab.sortAsc, key)
		end
	elseif inProjects(state) then
		if PROJECT_SORT_KEYS[key] then
			prefs.projectSort, prefs.projectSortAsc = model.nextSort(prefs.projectSort, prefs.projectSortAsc, key)
		end
	elseif SORT_KEYS[key] then
		prefs.sort, prefs.sortAsc = model.nextSort(prefs.sort, prefs.sortAsc, key)
	end
end

-- The client filters and search on screen.
local function clearFilters(state: BlockState)
	local tab = model.issuesTab(state)
	if tab ~= nil then
		tab.priority = nil
		tab.assignee = nil
		tab.labelId = nil
		text.set(tab.query, "")
		return
	end
	if inProjects(state) then
		state.prefs.projectLead = nil
		state.prefs.projectHealth = nil
		text.set(state.projects.query, "")
		return
	end
	state.prefs.priority = nil
	state.prefs.assignee = nil
	state.prefs.labelId = nil
	text.set(state.query, "")
end

local function copyText(state: BlockState, run: Run, value: string, label: string)
	state.cx:copy(value)
	setNotice(state, run, "Copied " .. label)
end

-- Only Linear's own pages are opened from an issue's or a project's `url`.
local function openLinearUrl(state: BlockState, run: Run, url: string)
	if string.match(url, "^https://linear%.app/") ~= nil then
		state.cx:open(url)
	else
		setNotice(state, run, "Refusing to open a link outside linear.app.")
		state.cx:render()
	end
end

-- Copies the project's URL, or its name when Linear sent no URL.
local function copyProject(state: BlockState, run: Run, project: Project)
	if project.url ~= "" then
		copyText(state, run, project.url, "link to " .. project.name)
	else
		copyText(state, run, project.name, project.name)
	end
end

-- Switches between projects and issues. Entering a mode whose list never loaded (or while a foreground load
-- runs) loads it in the foreground; otherwise the list shows at once and reloads in the background.
local function setMode(state: BlockState, run: Run, value: any)
	local mode: Mode? = parse.mode(value)
	if mode == nil or mode == state.prefs.mode or not canReload(state, run) then
		return
	end
	if mode == "projects" then
		-- The drawer, its inputs and the create dialog belong to issues mode.
		closeDrawer(state, run)
		if state.form ~= nil then
			cancelForm(state, run)
		end
	else
		-- The project page belongs to projects mode; coming back shows the list.
		closeProjectPage(state, run)
	end
	if state.focus == "search" then
		setFocus(state, nil)
	end
	state.prefs.mode = mode
	local loaded = if mode == "projects"
		then state.projects.fetchedAt ~= nil and #state.projects.statuses > 0
		else state.fetchedAt ~= nil
	if state.busy or not loaded or not run.metaReady then
		loadAll(state, run.metaReady)
	else
		reloadData(state, run)
	end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

type ActionHandler = (BlockState, Run, string?) -> ()

local function withIssue(state: BlockState, id: string?, use: (Issue) -> ())
	if id == nil then
		return
	end
	local issue = findIssue(state, id)
	if issue ~= nil then
		use(issue)
	end
end

local function withSelected(state: BlockState, use: (Issue) -> ())
	local issue = selectedIssue(state)
	if issue ~= nil then
		use(issue)
	end
end

local ACTIONS: { [string]: ActionHandler } = {
	["refresh"] = function(state, _run, _value)
		loadAll(state, false)
	end,
	["layout"] = function(state, _run, value)
		setLayout(state, value)
	end,
	["view"] = function(state, run, value)
		setView(state, run, value)
	end,
	["scope"] = function(state, run, value)
		if value == "mine" then
			setMine(state, run)
		end
	end,
	["team"] = function(state, run, value)
		if value ~= nil then
			setTeam(state, run, value)
		end
	end,
	["sort"] = function(state, _run, value)
		if value ~= nil then
			setSort(state, value)
		end
	end,
	["clear-filters"] = function(state, _run, _value)
		clearFilters(state)
	end,
	["focus-team"] = function(state, run, _value)
		nextTeam(state, run)
	end,
	["select"] = function(state, run, value)
		if value ~= nil then
			selectIssue(state, run, value, true, 0)
		end
	end,
	["close-detail"] = function(state, run, _value)
		closeDrawer(state, run)
	end,
	["open-url"] = function(state, run, value)
		withIssue(state, value, function(issue)
			openLinearUrl(state, run, issue.url)
		end)
	end,
	["copy-id"] = function(state, run, value)
		withIssue(state, value, function(issue)
			copyText(state, run, issue.identifier, issue.identifier)
		end)
	end,
	["copy-branch"] = function(state, run, value)
		withIssue(state, value, function(issue)
			copyText(state, run, issue.branchName, "branch name")
		end)
	end,
	["set-state"] = function(state, _run, value)
		withSelected(state, function(issue)
			local team = issueTeam(state, issue)
			if team == nil or value == nil then
				return
			end
			for _, workflowState in team.states do
				if workflowState.id == value then
					moveToState(state, issue, workflowState, "")
					return
				end
			end
		end)
	end,
	["assign-me"] = function(state, _run, _value)
		withSelected(state, function(issue)
			toggleAssignMe(state, issue)
		end)
	end,
	["unassign"] = function(state, _run, _value)
		withSelected(state, function(issue)
			if issue.assignee ~= nil then
				setAssignee(state, issue, nil)
			end
		end)
	end,
	["close-issue"] = function(state, _run, _value)
		withSelected(state, function(issue)
			closeIssue(state, issue)
		end)
	end,
	["reopen"] = function(state, _run, _value)
		withSelected(state, function(issue)
			reopenIssue(state, issue)
		end)
	end,
	["edit"] = function(state, run, _value)
		beginEdit(state, run)
	end,
	["create"] = function(state, _run, _value)
		openCreate(state)
	end,
	["submit-form"] = function(state, _run, _value)
		submitForm(state)
	end,
	["cancel-form"] = function(state, run, _value)
		cancelForm(state, run)
	end,
	["submit-comment"] = function(state, _run, _value)
		submitComment(state)
	end,
	["link"] = function(state, _run, value)
		local mode: ("blocked-by" | "blocks" | "related")? = parse.linkMode(value)
		if mode ~= nil then
			openLink(state, mode)
		end
	end,
	["submit-link"] = function(state, _run, _value)
		submitLink(state)
	end,
	["cancel-link"] = function(state, _run, _value)
		cancelLink(state)
	end,
	["unlink"] = function(state, _run, value)
		if value ~= nil then
			unlink(state, value)
		end
	end,
	["save-key"] = function(state, _run, _value)
		saveKey(state)
	end,
	["sign-out"] = function(state, run, _value)
		signOut(state, run)
	end,
	["mode"] = function(state, run, value)
		setMode(state, run, value)
	end,
	["project-scope"] = function(state, run, value)
		if value == "all" or value == "mine" then
			setProjectScope(state, run, value, nil)
		end
	end,
	["project-team"] = function(state, run, value)
		if value ~= nil then
			setProjectScope(state, run, "team", value)
		end
	end,
	["open-project"] = function(state, run, value)
		if value ~= nil then
			openProjectPage(state, run, value)
		end
	end,
	["project-back"] = function(state, run, _value)
		closeProjectPage(state, run)
	end,
	["project-tab"] = function(state, run, value)
		selectProjectTab(state, run, model.projectTab(value))
	end,
	["milestone"] = function(state, run, value)
		if value ~= nil then
			projectIssues.showMilestone(state, run, value)
		end
	end,
	["refresh-project"] = function(state, run, _value)
		refreshProjectTab(state, run)
	end,
	["activity-more"] = function(state, run, _value)
		local page = state.projectPage
		if page ~= nil and page.tab == "activity" and not page.activityLoading and not page.activityPaging then
			fetchActivity(state, run, "more")
		end
	end,
	["activity-comments"] = function(state, _run, value)
		local page = state.projectPage
		if page ~= nil and value ~= nil then
			if page.expandedUpdates[value] then
				page.expandedUpdates[value] = nil
			else
				page.expandedUpdates[value] = true
			end
		end
	end,
	["open-project-url"] = function(state, run, value)
		local project = if value ~= nil then knownProject(state, value) else nil
		if project ~= nil then
			openLinearUrl(state, run, project.url)
		end
	end,
	["copy-project-url"] = function(state, run, value)
		local project = if value ~= nil then knownProject(state, value) else nil
		if project ~= nil then
			copyProject(state, run, project)
		end
	end,
}

-- Where an action or select applies: "issues" (issues mode only), "projects" (projects mode only) or "issue" (an
-- issue list is on screen: issues mode, or the project page's Issues tab). A stale event from elsewhere is ignored.
type Gate = Mode | "issue"

local function gateOpen(state: BlockState, gate: Gate?): boolean
	if gate == nil then
		return true
	elseif gate == "issue" then
		return not inProjects(state) or model.issuesTab(state) ~= nil
	end
	return gate == state.prefs.mode
end

-- Unlisted actions apply in both modes. The drawer's and the selected issue's actions are "issue"; creating issues
-- and the issue scope stay in issues mode.
local ACTION_MODES: { [string]: Gate } = {
	["scope"] = "issues",
	["team"] = "issues",
	["focus-team"] = "issues",
	["create"] = "issues",
	["select"] = "issue",
	["close-detail"] = "issue",
	["open-url"] = "issue",
	["copy-id"] = "issue",
	["copy-branch"] = "issue",
	["set-state"] = "issue",
	["assign-me"] = "issue",
	["unassign"] = "issue",
	["close-issue"] = "issue",
	["reopen"] = "issue",
	["edit"] = "issue",
	["submit-form"] = "issue",
	["cancel-form"] = "issue",
	["submit-comment"] = "issue",
	["link"] = "issue",
	["submit-link"] = "issue",
	["cancel-link"] = "issue",
	["unlink"] = "issue",
	["project-scope"] = "projects",
	["project-team"] = "projects",
	["open-project"] = "projects",
	["project-back"] = "projects",
	["project-tab"] = "projects",
	["refresh-project"] = "projects",
	["milestone"] = "projects",
	["activity-more"] = "projects",
	["activity-comments"] = "projects",
	["open-project-url"] = "projects",
	["copy-project-url"] = "projects",
}

-- Actions that must not blur the field they were clicked from.
local KEEPS_FOCUS: { [string]: boolean } = {
	["submit-comment"] = true,
	["submit-link"] = true,
	["save-key"] = true,
}

local SETUP_ACTIONS: { [string]: boolean } = { ["save-key"] = true }

-- ─── Select keys ────────────────────────────────────────────────────────────

type SelectHandler = (BlockState, Run, string) -> ()

local function focusFormChoice(state: BlockState, name: string, value: string)
	local form = state.form
	if form == nil then
		return
	end
	for index, field in form.fields do
		if field.name == name and field.kind == "choice" then
			setChoice(state, form, field, value)
			form.focus = index
			setFocus(state, "form")
			return
		end
	end
end

local SELECTS: { [string]: SelectHandler } = {
	["team-select"] = function(state, run, value)
		if value == "mine" then
			setMine(state, run)
		else
			setTeam(state, run, value)
		end
	end,
	["filter-priority"] = function(state, _run, value)
		local priority = if value == "" then nil else tonumber(value)
		local tab = model.issuesTab(state)
		if tab ~= nil then
			tab.priority = priority
		else
			state.prefs.priority = priority
		end
	end,
	["filter-assignee"] = function(state, _run, value)
		local assignee = if value == "" then nil else value
		local tab = model.issuesTab(state)
		if tab ~= nil then
			tab.assignee = assignee
		else
			state.prefs.assignee = assignee
		end
	end,
	["filter-label"] = function(state, _run, value)
		local labelId = if value == "" then nil else value
		local tab = model.issuesTab(state)
		if tab ~= nil then
			tab.labelId = labelId
		else
			state.prefs.labelId = labelId
		end
	end,
	["state-select"] = function(state, run, value)
		ACTIONS["set-state"](state, run, value)
	end,
	["assignee-select"] = function(state, _run, value)
		withSelected(state, function(issue)
			setAssignee(state, issue, if value == "" then nil else value)
		end)
	end,
	["priority-select"] = function(state, _run, value)
		withSelected(state, function(issue)
			local priority = tonumber(value)
			if priority ~= nil then
				setPriority(state, issue, priority)
			end
		end)
	end,
	["project-scope-select"] = function(state, run, value)
		if value == "all" or value == "mine" then
			setProjectScope(state, run, value, nil)
		else
			setProjectScope(state, run, "team", value)
		end
	end,
	["filter-lead"] = function(state, _run, value)
		state.prefs.projectLead = if value == "" then nil else value
	end,
	["filter-health"] = function(state, _run, value)
		state.prefs.projectHealth = if value == "" then nil else value
	end,
	["milestone-select"] = function(state, run, value)
		if model.issuesTab(state) ~= nil then
			projectIssues.showMilestone(state, run, if value == "" then nil else value)
		end
	end,
}

-- Where each select applies (see Gate): the filter row's and the drawer's issue selects follow the issue list on
-- screen. Unlisted: both modes.
local SELECT_MODES: { [string]: Gate } = {
	["team-select"] = "issues",
	["filter-priority"] = "issue",
	["filter-assignee"] = "issue",
	["filter-label"] = "issue",
	["state-select"] = "issue",
	["assignee-select"] = "issue",
	["priority-select"] = "issue",
	["project-scope-select"] = "projects",
	["filter-lead"] = "projects",
	["filter-health"] = "projects",
	["milestone-select"] = "projects",
}

-- ─── Keys ───────────────────────────────────────────────────────────────────

type KeyHandler = (BlockState, Run) -> boolean

local function handleSetupKey(state: BlockState, k: Key): boolean
	if k.name == "enter" then
		saveKey(state)
		return true
	end
	if text.key(state.setupKey, k, false) then
		state.setupError = nil
		return true
	end
	return false
end

local function handleFormKey(state: BlockState, run: Run, k: Key): boolean
	local form = state.form
	if form == nil then
		setFocus(state, nil)
		return true
	end
	if formLocked(state, run) then
		return true
	end
	local field = form.fields[form.focus]
	if field == nil then
		return false
	end
	local name = k.name
	local isChoice = field.kind == "choice"
	local isMultiline = field.kind == "multiline"
	if name == "escape" then
		cancelForm(state, run)
		return true
	elseif name == "tab" then
		moveFormFocus(state, form, if k.shift then -1 else 1)
		return true
	elseif name == "enter" and (not isMultiline or k.ctrl or k.meta) then
		submitForm(state)
		return true
	end
	if isChoice then
		if k.ctrl or k.alt or k.meta then
			return false
		end
		if name == "up" or name == "left" then
			stepChoice(state, form, field, -1)
			return true
		elseif name == "down" or name == "right" then
			stepChoice(state, form, field, 1)
			return true
		end
		return false
	end
	local editable = field.field
	if editable == nil then
		return false
	end
	return text.key(editable, k, field.kind == "multiline")
end

local function handleFieldKey(state: BlockState, run: Run, k: Key): boolean
	local focus = state.focus
	local name = k.name
	if focus == "form" then
		return handleFormKey(state, run, k)
	elseif focus == "search" then
		if name == "escape" or name == "enter" then
			setFocus(state, nil)
			return true
		end
		return text.key(activeQuery(state), k, false)
	elseif focus == "comment" then
		if name == "escape" or name == "tab" then
			setFocus(state, nil)
			return true
		elseif name == "enter" and (k.ctrl or k.meta) then
			submitComment(state)
			return true
		end
		return text.key(state.comment, k, true)
	elseif focus == "link" then
		local link = state.link
		if link == nil then
			setFocus(state, nil)
			return true
		elseif name == "escape" then
			cancelLink(state)
			return true
		elseif name == "enter" then
			submitLink(state)
			return true
		end
		return text.key(link.field, k, false)
	end
	return false
end

local function viewKey(value: "active" | "backlog" | "all"): KeyHandler
	return function(state, run)
		setView(state, run, value)
		return true
	end
end

local function selectedAction(use: (BlockState, Run, Issue) -> ()): KeyHandler
	return function(state, run)
		local issue = selectedIssue(state)
		if issue == nil then
			return false
		end
		use(state, run, issue)
		return true
	end
end

-- A selection key: `step(state, run, delta)` (issues or projects, rows or columns).
local function stepKey(step: (BlockState, Run, number) -> boolean, delta: number): KeyHandler
	return function(state, run)
		return step(state, run, delta)
	end
end

local function escapeKey(state: BlockState, run: Run): boolean
	if state.form ~= nil then
		cancelForm(state, run)
	elseif state.link ~= nil then
		cancelLink(state)
	elseif state.drawerOpen then
		closeDrawer(state, run)
	elseif model.selectedIssueId(state) ~= nil then
		clearSelection(state, run)
	else
		return false
	end
	return true
end

local KEYS: { [string]: KeyHandler } = {
	["/"] = function(state, _run)
		setFocus(state, "search")
		return true
	end,
	["1"] = viewKey("active"),
	["2"] = viewKey("backlog"),
	["3"] = viewKey("all"),
	["v"] = function(state, _run)
		setLayout(state, if state.prefs.layout == "board" then "table" else "board")
		return true
	end,
	["m"] = function(state, run)
		setMine(state, run)
		return true
	end,
	["t"] = nextTeam,
	["j"] = stepKey(moveSelection, 1),
	["down"] = stepKey(moveSelection, 1),
	["k"] = stepKey(moveSelection, -1),
	["up"] = stepKey(moveSelection, -1),
	["h"] = stepKey(moveColumn, -1),
	["left"] = stepKey(moveColumn, -1),
	["l"] = stepKey(moveColumn, 1),
	["right"] = stepKey(moveColumn, 1),
	["enter"] = function(state, run)
		local id = model.selectedIssueId(state)
		if id == nil or state.drawerOpen then
			return false
		end
		selectIssue(state, run, id, true, 0)
		return true
	end,
	["escape"] = escapeKey,
	["n"] = function(state, _run)
		openCreate(state)
		return true
	end,
	["e"] = selectedAction(function(state, run, _issue)
		beginEdit(state, run)
	end),
	["c"] = function(state, _run)
		if not state.drawerOpen or state.form ~= nil then
			return false
		end
		setFocus(state, "comment")
		return true
	end,
	["a"] = selectedAction(function(state, _run, issue)
		toggleAssignMe(state, issue)
	end),
	["x"] = selectedAction(function(state, _run, issue)
		toggleClosed(state, issue)
	end),
	["["] = selectedAction(function(state, run, issue)
		moveAdjacent(state, run, issue, -1)
	end),
	["]"] = selectedAction(function(state, run, issue)
		moveAdjacent(state, run, issue, 1)
	end),
	["o"] = selectedAction(function(state, run, issue)
		openLinearUrl(state, run, issue.url)
	end),
	["y"] = selectedAction(function(state, run, issue)
		copyText(state, run, issue.identifier, issue.identifier)
	end),
	["r"] = function(state, _run)
		loadAll(state, false)
		return true
	end,
	["p"] = function(state, run)
		setMode(state, run, "projects")
		return true
	end,
	["i"] = function(state, run)
		setMode(state, run, "issues")
		return true
	end,
}

local function selectedProjectAction(use: (BlockState, Run, Project) -> ()): KeyHandler
	return function(state, run)
		local project = selectedProject(state)
		if project == nil then
			return false
		end
		use(state, run, project)
		return true
	end
end

-- Projects mode: the issue keys without an issue to act on (n e c a x [ ]) are absent; `enter` opens the project page.
local PROJECT_KEYS: { [string]: KeyHandler } = {
	["/"] = KEYS["/"],
	["1"] = KEYS["1"],
	["2"] = KEYS["2"],
	["3"] = KEYS["3"],
	["v"] = KEYS["v"],
	["r"] = KEYS["r"],
	["p"] = KEYS["p"],
	["i"] = KEYS["i"],
	-- My projects, or back to All projects when already there.
	["m"] = function(state, run)
		if state.prefs.projectScope == "mine" then
			setProjectScope(state, run, "all", nil)
		else
			setProjectScope(state, run, "mine", nil)
		end
		return true
	end,
	["t"] = nextProjectTeam,
	["j"] = stepKey(moveProjectSelection, 1),
	["down"] = stepKey(moveProjectSelection, 1),
	["k"] = stepKey(moveProjectSelection, -1),
	["up"] = stepKey(moveProjectSelection, -1),
	["h"] = stepKey(moveProjectColumn, -1),
	["left"] = stepKey(moveProjectColumn, -1),
	["l"] = stepKey(moveProjectColumn, 1),
	["right"] = stepKey(moveProjectColumn, 1),
	-- Only a project the list shows: search and the lead/health filters keep a selection they hide.
	["enter"] = function(state, run)
		local id = state.projects.selectedId
		if id == nil then
			return false
		end
		for _, project in visibleProjects(state) do
			if project.id == id then
				openProjectPage(state, run, id)
				return true
			end
		end
		return false
	end,
	["escape"] = function(state, _run)
		if state.projects.selectedId == nil then
			return false
		end
		clearProjectSelection(state)
		return true
	end,
	["o"] = selectedProjectAction(function(state, run, project)
		openLinearUrl(state, run, project.url)
	end),
	["y"] = selectedProjectAction(copyProject),
}

-- The project page's Issues tab: issues mode's keys for the tab's list, selection and drawer. Absent: `n` (no
-- create), `m` / `t` (no scope), `r`, `p`, `i` and `escape` (the page handles them).
local ISSUES_TAB_KEYS: { [string]: KeyHandler } = {}
for _, name in
	{
		"/",
		"1",
		"2",
		"3",
		"v",
		"j",
		"down",
		"k",
		"up",
		"h",
		"left",
		"l",
		"right",
		"enter",
		"e",
		"c",
		"a",
		"x",
		"[",
		"]",
		"o",
		"y",
	}
do
	ISSUES_TAB_KEYS[name] = KEYS[name]
end

-- The project page hides the list, so none of the list's keys apply. On the Issues tab its issue keys come first:
-- `escape` closes the form, the link input, the drawer, then clears the selection, and only then goes back; `o` /
-- `y` act on the selected issue, and on the project when nothing is selected.
local function handlePageKey(state: BlockState, run: Run, page: types.ProjectPageState, k: Key): boolean
	local name = k.name
	if page.tab == "issues" then
		if name == "escape" then
			if escapeKey(state, run) then
				return true
			end
		else
			local handler = ISSUES_TAB_KEYS[name]
			if handler ~= nil and handler(state, run) then
				return true
			end
		end
	end
	if name == "escape" or name == "backspace" or name == "p" then
		closeProjectPage(state, run)
		return true
	elseif name == "tab" then
		if #model.PROJECT_TABS < 2 then
			return false
		end
		selectProjectTab(state, run, model.stepProjectTab(page.tab, if k.shift then -1 else 1))
		return true
	elseif name == "r" then
		refreshProjectTab(state, run)
		return true
	elseif name == "i" then
		setMode(state, run, "issues")
		return true
	elseif name == "o" or name == "y" then
		local project = knownProject(state, page.projectId)
		if project == nil then
			return false
		end
		if name == "o" then
			openLinearUrl(state, run, project.url)
		else
			copyProject(state, run, project)
		end
		return true
	end
	return false
end

local function handleKey(state: BlockState, k: Key, _cx: BlockCx): boolean?
	local run = runOf(state)
	if run == nil then
		return false
	end
	if state.phase == "setup" then
		return handleSetupKey(state, k)
	elseif state.phase ~= "ready" then
		return false
	end
	if state.focus ~= nil then
		return handleFieldKey(state, run, k)
	end
	if k.ctrl or k.alt or k.meta then
		return false
	end
	local page = if inProjects(state) then state.projectPage else nil
	if page ~= nil then
		return handlePageKey(state, run, page, k)
	end
	local handler = (if inProjects(state) then PROJECT_KEYS else KEYS)[k.name]
	if handler == nil then
		return false
	end
	return handler(state, run)
end

-- ─── Events ─────────────────────────────────────────────────────────────────

-- Maps a view field name to its focus key, editable text and (form fields) index.
local function resolveField(state: BlockState, name: string): (string?, Field?, number?)
	-- The Issues tab's search field is the "search" focus while the tab is on screen (activeQuery is its text).
	if name == "search" or (name == "project-search" and model.issuesTab(state) ~= nil) then
		return "search", activeQuery(state), nil
	elseif name == "setup" then
		return "setup", state.setupKey, nil
	elseif name == "comment" then
		return "comment", state.comment, nil
	elseif name == "link" then
		local link = state.link
		if link == nil then
			return nil, nil, nil
		end
		return "link", link.field, nil
	end
	local formField = string.match(name, "^form:(.+)$")
	local form = state.form
	if formField == nil or form == nil then
		return nil, nil, nil
	end
	for index, field in form.fields do
		if field.name == formField then
			return "form", field.field, index
		end
	end
	return nil, nil, nil
end

local function fieldOfEvent(state: BlockState, ev: UiEvent): (string?, Field?, number?)
	local id = ev.id
	if type(id) ~= "string" then
		return nil, nil, nil
	end
	local name = view.fieldName(id)
	if name == nil then
		return nil, nil, nil
	end
	return resolveField(state, name)
end

local function onFocus(state: BlockState, ev: UiEvent)
	local focus, _, index = fieldOfEvent(state, ev)
	if focus == nil then
		return
	end
	local form = state.form
	if index ~= nil and form ~= nil then
		form.focus = index
	end
	setFocus(state, focus)
end

local function onEdit(state: BlockState, run: Run, ev: UiEvent)
	local focus, field, index = fieldOfEvent(state, ev)
	if focus == nil or field == nil then
		return
	end
	if focus == "form" and formLocked(state, run) then
		return
	end
	if not text.applyEdit(field, ev) then
		return
	end
	state.focus = focus
	local form = state.form
	if index ~= nil and form ~= nil then
		form.focus = index
	end
	if focus == "setup" then
		state.setupError = nil
	end
end

-- Selects whose pick may go unapplied (refused, rejected or failed); they remount to the real value.
local REMOUNTING_SELECTS: { [string]: boolean } = {
	["team-select"] = true,
	["project-scope-select"] = true,
	["state-select"] = true,
	["assignee-select"] = true,
	["priority-select"] = true,
}

-- Select keys carry the control epoch (`state-select-e2`); dispatch is on the key without it.
local function baseKey(key: string): string
	return (string.gsub(key, "%-e%d+$", ""))
end

local function onAction(state: BlockState, run: Run, ev: UiEvent)
	local act = ev.act
	if type(act) ~= "string" then
		return
	end
	local handler = ACTIONS[act]
	if handler == nil then
		return
	end
	if state.phase == "setup" then
		if not SETUP_ACTIONS[act] then
			return
		end
	elseif state.phase ~= "ready" then
		return
	end
	if not gateOpen(state, ACTION_MODES[act]) then
		return
	end
	if not KEEPS_FOCUS[act] then
		blurTextFocus(state)
	end
	-- Table button cells and row menus name the row in `item`.
	local value = stringValue(ev.value) or stringValue(ev.item)
	handler(state, run, value)
end

local function onChange(state: BlockState, run: Run, ev: UiEvent)
	local id = ev.id
	local value = stringValue(ev.value)
	if type(id) ~= "string" or value == nil or state.phase ~= "ready" then
		return
	end
	local last = string.match(id, "([^%.]+)$")
	if last == nil then
		return
	end
	local key = baseKey(last)
	local formName = string.match(key, "^f%-(.+)$")
	if formName ~= nil then
		if formLocked(state, run) then
			bumpControls(state)
		else
			focusFormChoice(state, formName, value)
		end
		return
	end
	local handler = SELECTS[key]
	if handler ~= nil and gateOpen(state, SELECT_MODES[key]) then
		blurTextFocus(state)
		local before = state.generation
		handler(state, run, value)
		if state.generation == before and REMOUNTING_SELECTS[key] then
			bumpControls(state)
		end
	end
end

-- Table row events. Issues (issues mode, or the project page's Issues tab): `select` highlights (and follows an open
-- drawer), `activate` opens the drawer. Projects: `select` selects the project, `activate` opens its page.
local function onRow(state: BlockState, run: Run, ev: UiEvent, open: boolean)
	local item = ev.item
	if type(item) ~= "string" or state.phase ~= "ready" then
		return
	end
	if inProjects(state) and model.issuesTab(state) == nil then
		if findProject(state, item) ~= nil and state.projectPage == nil then
			blurTextFocus(state)
			if open then
				openProjectPage(state, run, item)
			else
				selectProject(state, item)
			end
		end
		return
	end
	if findIssue(state, item) == nil then
		return
	end
	blurTextFocus(state)
	selectIssue(state, run, item, open, 0)
end

local function handleEvent(state: BlockState, ev: UiEvent, _cx: BlockCx)
	local run = runOf(state)
	if run == nil then
		return
	end
	local kind = ev.ev
	if kind == "focus" then
		onFocus(state, ev)
	elseif kind == "edit" then
		onEdit(state, run, ev)
	elseif kind == "action" then
		onAction(state, run, ev)
	elseif kind == "change" then
		onChange(state, run, ev)
	elseif kind == "select" then
		onRow(state, run, ev, state.drawerOpen)
	elseif kind == "activate" then
		onRow(state, run, ev, true)
	end
end

-- ─── Block definition ───────────────────────────────────────────────────────

local function startRun(state: BlockState, run: Run)
	local cfg, rejected = credentials.resolve()
	if cfg == nil then
		enterSetup(state, run, rejected)
	else
		run.cfg = cfg
		state.keySource = credentials.source()
		state.phase = "loading"
		loadAll(state, false)
		-- A restored project page loads beside the list (and its Activity tab when that was the saved tab); it
		-- shows once the list is ready.
		fetchProjectPage(state, run, true)
		local page = state.projectPage
		if page ~= nil then
			selectProjectTab(state, run, page.tab)
		end
	end
	schedulePoll(state, run)
end

local function register(state: BlockState): Run
	local previous = runs[state.cx.pane]
	if previous ~= nil then
		retire(previous)
	end
	local run: Run = {
		state = state,
		cfg = nil,
		poll = nil,
		noticeTimer = nil,
		detailTimer = nil,
		detailToken = 0,
		pageToken = 0,
		projectsSeq = 0,
		goneProjects = {},
		readyNotice = nil,
		activityToken = 0,
		issuesToken = 0,
		issuesInFlight = false,
		issuesFullAt = tern.now(),
		fgKind = nil,
		lastFullAt = tern.now(),
		focusQueued = false,
		reloadQueued = false,
		editAfterLoad = nil,
		metaReady = false,
	}
	runs[state.cx.pane] = run
	return run
end

local function blockTitle(state: BlockState): string
	if state.phase ~= "ready" then
		return "Linear"
	end
	local prefs = state.prefs
	if prefs.mode == "projects" then
		local page = state.projectPage
		if page ~= nil then
			local project = knownProject(state, page.projectId)
			return if project ~= nil then `Linear · {project.name}` else "Linear · Project"
		end
		if prefs.projectScope == "mine" then
			return "Linear · My projects"
		end
		local team = if prefs.projectScope == "team" then teamById(state, prefs.projectTeamId) else nil
		if team ~= nil then
			return `Linear · Projects · {team.key}`
		end
		return "Linear · Projects"
	end
	local team = scopeTeam(state)
	if team ~= nil then
		return "Linear · " .. team.key
	end
	return "Linear · My issues"
end

local featureList: { "edit" | "undo" } = { "edit" }

local def: BlockDef<BlockState> = {
	font = "sans",
	features = featureList,
	init = function(cx, _args, saved)
		local state = newState(cx, restorePrefs(saved))
		if state.prefs.mode == "projects" then
			state.projectPage = restorePage(saved)
		end
		startRun(state, register(state))
		return state
	end,
	view = function(state, cx)
		return view.render(state, cx)
	end,
	title = blockTitle,
	key = handleKey,
	event = handleEvent,
	save = function(state)
		local prefs = state.prefs
		local page = state.projectPage
		return {
			mode = prefs.mode,
			sort = prefs.sort,
			sortAsc = prefs.sortAsc,
			scope = prefs.scope,
			teamId = prefs.teamId,
			view = prefs.view,
			layout = prefs.layout,
			projectScope = prefs.projectScope,
			projectTeamId = prefs.projectTeamId,
			projectView = prefs.projectView,
			projectSort = prefs.projectSort,
			projectSortAsc = prefs.projectSortAsc,
			-- The open project page, reopened on restore (projects mode only), with the Issues tab's milestone filter.
			projectPage = if prefs.mode == "projects" and page ~= nil
				then { id = page.projectId, tab = page.tab, milestoneId = page.issues.milestoneId }
				else nil,
		}
	end,
}

local controller = { def = def }

return controller
