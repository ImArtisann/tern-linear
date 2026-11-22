--!strict
-- Shared types for tern-linear. This file is the contract between modules:
-- data (linear, credentials, queries), model, text, controller and views.
-- See docs/ARCHITECTURE.md for the semantics behind every field.

local types = {}

-- ─── Linear entities (normalized; never raw GraphQL) ────────────────────────

export type User = {
	id: string,
	name: string,
	displayName: string,
	avatarUrl: string?,
	active: boolean?,
}

export type WorkflowState = {
	id: string,
	name: string,
	-- "triage" | "backlog" | "unstarted" | "started" | "completed" | "canceled" | "duplicate"
	type: string,
	color: string,
	position: number,
}

export type Label = {
	id: string,
	name: string,
	color: string,
	isGroup: boolean?,
}

export type Team = {
	id: string,
	key: string,
	name: string,
	color: string?,
	cyclesEnabled: boolean,
	triageEnabled: boolean,
	-- Team.issueEstimationType: "notUsed" | "exponential" | "fibonacci" | "linear" | "tShirt"
	estimation: string,
	defaultStateId: string?,
	-- Sorted by (type rank, position) — see model.STATE_TYPES.
	states: { WorkflowState },
	-- Group labels (isGroup) are already removed.
	labels: { Label },
	-- Active members only.
	members: { User },
}

export type IssueRef = {
	id: string,
	identifier: string,
	title: string,
	stateType: string,
	stateName: string?,
}

-- One relation row seen from the issue that owns it.
-- direction "outgoing": this issue is the source (`Issue.relations`).
-- direction "incoming": this issue is the target (`Issue.inverseRelations`).
-- type "blocks" + outgoing  => this issue blocks `other`.
-- type "blocks" + incoming  => this issue is blocked by `other`.
export type Relation = {
	id: string,
	type: string,
	direction: "outgoing" | "incoming",
	other: IssueRef,
}

export type Comment = {
	id: string,
	body: string,
	createdAt: string,
	parentId: string?,
	-- nil for bots/integrations; render "Linear" or similar.
	user: User?,
}

export type Issue = {
	id: string,
	identifier: string,
	number: number,
	title: string,
	-- Markdown; only present after a detail fetch (`detailed == true`).
	description: string?,
	-- 0 none, 1 urgent, 2 high, 3 medium, 4 low
	priority: number,
	priorityLabel: string,
	estimate: number?,
	url: string,
	branchName: string,
	createdAt: string,
	updatedAt: string,
	completedAt: string?,
	canceledAt: string?,
	archivedAt: string?,
	-- "YYYY-MM-DD"
	dueDate: string?,
	sortOrder: number,
	state: WorkflowState,
	teamId: string,
	teamKey: string,
	assignee: User?,
	creator: User?,
	labels: { Label },
	project: { id: string, name: string }?,
	cycle: { id: string, number: number, name: string? }?,
	parent: IssueRef?,
	children: { IssueRef },
	relations: { Relation },
	-- Ascending by createdAt; only present after a detail fetch.
	comments: { Comment }?,
	detailed: boolean,
}

export type Viewer = {
	user: User,
	organization: { id: string, name: string, urlKey: string },
}

-- One of the organization's project statuses (Linear's `ProjectStatus`).
export type ProjectStatus = {
	id: string,
	name: string,
	-- ProjectStatusType: "backlog" | "planned" | "started" | "paused" | "completed" | "canceled"
	type: string,
	color: string,
	position: number,
}

export type ProjectTeam = { id: string, key: string, name: string }

export type Project = {
	id: string,
	name: string,
	-- https://linear.app/<org>/project/<slug>
	url: string,
	slugId: string,
	-- Linear icon name (e.g. "Rocket"); display-only, nil when unset.
	icon: string?,
	color: string,
	-- Linear's short summary (`Project.description`), not the long document (`content`).
	summary: string,
	status: ProjectStatus,
	-- "onTrack" | "atRisk" | "offTrack"; nil until the first project update.
	health: string?,
	-- 0..1
	progress: number,
	lead: User?,
	-- "YYYY-MM-DD"
	startDate: string?,
	targetDate: string?,
	-- 0 none, 1 urgent, 2 high, 3 medium, 4 low
	priority: number,
	sortOrder: number,
	-- The first PROJECT_TEAMS (5) teams of `Project.teams`.
	teams: { ProjectTeam },
	createdAt: string,
	updatedAt: string,
	startedAt: string?,
	completedAt: string?,
	canceledAt: string?,
}

-- One of a project's milestones (Linear's `ProjectMilestone`).
export type ProjectMilestone = {
	id: string,
	name: string,
	-- ProjectMilestoneStatus: "unstarted" | "next" | "overdue" | "done" (computed by Linear)
	status: string,
	-- 0..1 (Linear sends 0..100; the normalizer divides)
	progress: number,
	-- "YYYY-MM-DD"
	targetDate: string?,
	-- Linear's manual order; model.sortMilestones orders by it.
	sortOrder: number,
}

-- A project as the project page shows it: the list fields plus the overview's own.
export type ProjectDetail = {
	-- The list fields, from the same normalizer as `Project` (teams: the first 10 instead of 5).
	project: Project,
	-- The long project document (`Project.content`), Markdown; "" when there is none.
	content: string,
	-- When the health was last set by a project update.
	healthUpdatedAt: string?,
	-- DateResolutionType of `project.startDate` / `project.targetDate`: "month" | "quarter" | "halfYear" | "year";
	-- nil for an exact date.
	startDateResolution: string?,
	targetDateResolution: string?,
	members: { User },
	-- Project labels (no group labels).
	labels: { Label },
	-- Linear's order (model.sortMilestones): sortOrder, then target date, then name.
	milestones: { ProjectMilestone },
	-- The project has more milestones than the query's first 50.
	milestonesTruncated: boolean,
}

-- ─── Data layer ─────────────────────────────────────────────────────────────

export type Config = {
	key: string,
	endpoint: string,
}

export type ApiErrorKind = "auth" | "forbidden" | "rate" | "network" | "input" | "notfound" | "server"

export type ApiError = {
	kind: ApiErrorKind,
	-- Human-readable, safe to show (never contains the key).
	message: string,
	-- Present for kind "rate": milliseconds to wait before the next request.
	retryAfterMs: number?,
}

export type Callback<T> = (result: T?, err: ApiError?) -> ()

export type IssuePage = {
	issues: { Issue },
	-- True when MAX_ISSUES was reached and more matched on the server.
	truncated: boolean,
}

export type ProjectPage = {
	projects: { Project },
	-- True when MAX_PROJECTS was reached and more matched on the server.
	truncated: boolean,
}

export type RateInfo = {
	requestsRemaining: number?,
	requestsLimit: number?,
	complexityRemaining: number?,
	-- Epoch milliseconds.
	resetAt: number?,
}

export type IssueCreateInput = {
	teamId: string,
	title: string,
	description: string?,
	priority: number?,
	assigneeId: string?,
	stateId: string?,
	labelIds: { string }?,
	parentId: string?,
}

-- ─── Text fields (lib/text.luau) ────────────────────────────────────────────

-- A controlled text field. Offsets are UTF-16 code units (Tern's contract).
export type Field = {
	text: string,
	cursor: number,
	anchor: number?,
}

-- ─── Board preferences (persisted by `save`) ────────────────────────────────

export type Mode = "projects" | "issues"

export type Prefs = {
	-- Which list the block shows. Saved prefs without a valid mode fall back to "projects".
	mode: Mode,
	-- "mine": issues assigned to the viewer across teams; "team": every issue of `teamId`.
	scope: "mine" | "team",
	teamId: string?,
	-- "active": triage/unstarted/started; "backlog": backlog; "all": everything,
	-- closed ones only when closed in the last 14 days.
	view: "active" | "backlog" | "all",
	-- Shared by both modes.
	layout: "board" | "table",
	-- Table sort column: "identifier" | "title" | "state" | "priority" | "assignee" | "updated"
	sort: string,
	sortAsc: boolean,
	-- Client-side filters; nil means "any".
	priority: number?,
	-- "me" | "none" | <user id>
	assignee: string?,
	labelId: string?,

	-- Projects mode. "all": every project; "mine": the viewer leads or is a member;
	-- "team": projects whose accessibleTeams include `projectTeamId`.
	projectScope: "all" | "mine" | "team",
	projectTeamId: string?,
	-- By ProjectStatusType: "active": planned/started/paused; "backlog": backlog; "all": every type.
	projectView: "active" | "backlog" | "all",
	-- Table sort column: "name" | "status" | "health" | "lead" | "target" | "progress" | "updated"
	projectSort: string,
	projectSortAsc: boolean,
	-- Client-side filters (not saved); nil means "any".
	-- "me" | "none" | <user id>
	projectLead: string?,
	-- "onTrack" | "atRisk" | "offTrack" | "none"
	projectHealth: string?,
}

-- ─── Forms ──────────────────────────────────────────────────────────────────

export type FormOption = { value: string, label: string }

export type FormField = {
	-- Stable name: "title" | "description" | "team" | "state" | "priority" | "assignee" | "labels" | "estimate"
	name: string,
	label: string,
	kind: "text" | "multiline" | "choice",
	-- text / multiline fields
	field: Field?,
	-- choice fields; "" means none
	value: string?,
	options: { FormOption }?,
	-- Value when the form opened; edit submits only fields that differ.
	baseline: string,
	placeholder: string?,
}

export type Form = {
	kind: "create" | "edit",
	-- edit: the issue being edited
	issueId: string?,
	fields: { FormField },
	-- Index into `fields` that owns the keyboard.
	focus: number,
	error: string?,
}

-- Inline "link issue" input inside the drawer.
export type LinkDraft = {
	-- "blocked-by": the selected issue is blocked by the typed one.
	-- "blocks": the selected issue blocks the typed one.
	-- "related": plain relation.
	mode: "blocked-by" | "blocks" | "related",
	field: Field,
	error: string?,
}

-- ─── Block state (lib/controller.luau owns all mutation) ────────────────────

-- Projects mode: the project list, its search text and selection. The issue counterparts are
-- top-level BlockState fields; the project page (opened from this list) keeps its own state beside it.
export type ProjectsState = {
	items: { Project },
	-- The organization's statuses (board columns), sorted by type rank then position.
	statuses: { ProjectStatus },
	truncated: boolean,
	-- Epoch seconds of the last successful project load; nil until projects were loaded once.
	fetchedAt: number?,
	-- Greatest updatedAt seen under the current project filter (ISO string, server clock).
	maxUpdatedAt: string?,
	-- Search text of projects mode (the search field shows the active mode's query).
	query: Field,
	selectedId: string?,
}

-- A tab of the project page. Each tab is one entry of model.PROJECT_TABS (the tab bar's order); a layer that
-- adds a tab extends this union and that list, and keeps its own data in ProjectPageState.
export type ProjectTab = "overview"

-- The project page: full-screen over projects mode's list, which stays loaded (scope, view, layout and
-- selection untouched) for Back.
export type ProjectPageState = {
	projectId: string,
	tab: ProjectTab,
	-- The overview's data; nil until the first detail load. The header falls back to the list item.
	detail: ProjectDetail?,
	-- A shown detail request is in flight (open, `r`, Refresh); poll reloads keep it false.
	loading: boolean,
	-- The last detail load failed (shown in the page; the known fields stay).
	error: string?,
	-- Epoch seconds of the last successful detail load.
	fetchedAt: number?,
}

export type BlockState = {
	cx: BlockCx,
	-- "setup": no key yet; "loading": first load in flight; "ready": data shown.
	phase: "setup" | "loading" | "ready",
	keySource: ("env" | "file")?,
	setupKey: Field,
	setupError: string?,

	viewer: Viewer?,
	teams: { Team },
	issues: { Issue },
	truncated: boolean,
	-- Epoch seconds of the last successful board load.
	fetchedAt: number?,
	-- Greatest updatedAt seen in the current scope (ISO string, server clock).
	maxUpdatedAt: string?,
	-- Projects mode data and selection (mode "projects").
	projects: ProjectsState,
	-- The open project page (projects mode only); nil shows the list.
	projectPage: ProjectPageState?,

	prefs: Prefs,
	query: Field,
	-- Which field owns the keyboard: nil | "search" | "setup" | "comment" | "link" | "form"
	focus: string?,

	selectedId: string?,
	-- Full issue for the drawer; nil until loaded.
	detail: Issue?,
	detailLoading: boolean,
	-- Drawer open (selectedId set and user opened details).
	drawerOpen: boolean,
	comment: Field,
	link: LinkDraft?,
	form: Form?,

	-- A foreground request is in flight: actions that mutate are disabled.
	busy: boolean,
	-- A background read is in flight: never gates input.
	refreshing: boolean,
	-- A foreground load started over an already-ready board; the issue list is not authoritative yet.
	reloading: boolean,
	-- Bumped when a select must remount to show the authoritative value (it is part of the select's key).
	controlEpoch: number,
	generation: number,
	error: string?,
	-- Transient success/info line (e.g. "Created ENG-12").
	notice: string?,
	-- Epoch ms until which background polling is paused (rate limit backoff).
	backoffUntil: number?,
}

return types
