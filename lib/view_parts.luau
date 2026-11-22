--!strict
-- Small node builders and tone tables shared by the `main` views (view.luau: list; view_project.luau: project page).
-- Pure: builds nodes from values, never reads or mutates block state.

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

return parts
