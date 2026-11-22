--!strict
-- GraphQL documents for tern-linear: one named operation per string, operation name == key.
-- test/validate-queries.mjs extracts every `queries.<Name> = [[...]]` and validates it against Linear's SDL.
-- Every nested connection carries an explicit `first`: Linear's default of 50 multiplies query complexity.
-- Issues, IssueCreate and IssueUpdate share one node selection so a mutation result can be spliced into the board.

local queries = {}

queries.Viewer = [[query Viewer {
  viewer { id name displayName avatarUrl organization { id name urlKey } }
}]]

-- Nested connections are capped (states 40, labels 100, members 100); each carries pageInfo so
-- linear.teams can follow up with TeamMore for any team that overflows.
queries.Teams = [[query Teams($first: Int = 5, $after: String) {
  teams(first: $first, after: $after) {
    nodes {
      id key name color
      cyclesEnabled triageEnabled issueEstimationType
      defaultIssueState { id }
      states(first: 40) { nodes { id name type color position } pageInfo { hasNextPage endCursor } }
      labels(first: 100) { nodes { id name color isGroup } pageInfo { hasNextPage endCursor } }
      members(first: 100) { nodes { id name displayName avatarUrl active } pageInfo { hasNextPage endCursor } }
    }
    pageInfo { hasNextPage endCursor }
  }
}]]

queries.TeamMore = [[query TeamMore($id: String!, $statesAfter: String, $labelsAfter: String, $membersAfter: String) {
  team(id: $id) {
    id
    states(first: 40, after: $statesAfter) { nodes { id name type color position } pageInfo { hasNextPage endCursor } }
    labels(first: 100, after: $labelsAfter) { nodes { id name color isGroup } pageInfo { hasNextPage endCursor } }
    members(first: 100, after: $membersAfter) { nodes { id name displayName avatarUrl active } pageInfo { hasNextPage endCursor } }
  }
}]]

queries.Issues =
	[[query Issues($filter: IssueFilter, $first: Int = 50, $after: String, $orderBy: PaginationOrderBy = updatedAt, $includeArchived: Boolean = false) {
  issues(filter: $filter, first: $first, after: $after, orderBy: $orderBy, includeArchived: $includeArchived) {
    nodes {
      id identifier number title priority priorityLabel estimate url branchName
      createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
      state { id name type color position }
      team { id key }
      assignee { id name displayName avatarUrl }
      labels(first: 10) { nodes { id name color } }
      project { id name }
      cycle { id number name }
      parent { id identifier title state { name type } }
      children(first: 10) { nodes { id identifier title state { name type } } }
      relations(first: 5) { nodes { id type relatedIssue { id identifier title state { name type } } } }
      inverseRelations(first: 10) { nodes { id type issue { id identifier title state { name type } } } }
    }
    pageInfo { hasNextPage endCursor }
  }
}]]

queries.Issue = [[query Issue($id: String!, $commentsFirst: Int = 50, $commentsAfter: String) {
  issue(id: $id) {
    id identifier number title description priority priorityLabel estimate url branchName
    createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
    state { id name type color position }
    team { id key }
    creator { id name displayName avatarUrl }
    assignee { id name displayName avatarUrl }
    labels(first: 25) { nodes { id name color } }
    project { id name }
    cycle { id number name }
    parent { id identifier title state { name type } }
    children(first: 50) { nodes { id identifier title state { name type } } }
    relations(first: 25) { nodes { id type relatedIssue { id identifier title state { name type } } } }
    inverseRelations(first: 25) { nodes { id type issue { id identifier title state { name type } } } }
    comments(first: $commentsFirst, after: $commentsAfter, orderBy: createdAt) {
      nodes { id body createdAt parentId user { id name displayName avatarUrl } }
      pageInfo { hasNextPage endCursor }
    }
  }
}]]

queries.IssueCreate = [[mutation IssueCreate($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id identifier number title priority priorityLabel estimate url branchName
      createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
      state { id name type color position }
      team { id key }
      assignee { id name displayName avatarUrl }
      labels(first: 10) { nodes { id name color } }
      project { id name }
      cycle { id number name }
      parent { id identifier title state { name type } }
      children(first: 10) { nodes { id identifier title state { name type } } }
      relations(first: 5) { nodes { id type relatedIssue { id identifier title state { name type } } } }
      inverseRelations(first: 10) { nodes { id type issue { id identifier title state { name type } } } }
    }
  }
}]]

queries.IssueUpdate = [[mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue {
      id identifier number title priority priorityLabel estimate url branchName
      createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
      state { id name type color position }
      team { id key }
      assignee { id name displayName avatarUrl }
      labels(first: 10) { nodes { id name color } }
      project { id name }
      cycle { id number name }
      parent { id identifier title state { name type } }
      children(first: 10) { nodes { id identifier title state { name type } } }
      relations(first: 5) { nodes { id type relatedIssue { id identifier title state { name type } } } }
      inverseRelations(first: 10) { nodes { id type issue { id identifier title state { name type } } } }
    }
  }
}]]

queries.CommentCreate = [[mutation CommentCreate($input: CommentCreateInput!) {
  commentCreate(input: $input) {
    success
    comment { id body createdAt parentId user { id name displayName avatarUrl } }
  }
}]]

queries.IssueRelationCreate = [[mutation IssueRelationCreate($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) {
    success
    issueRelation { id type }
  }
}]]

queries.IssueRelationDelete = [[mutation IssueRelationDelete($id: String!) {
  issueRelationDelete(id: $id) { success entityId }
}]]

-- Resolves "ENG-123" (or a UUID): Query.issue(id: String!) accepts both forms.
queries.IssueLookup = [[query IssueLookup($id: String!) {
  issue(id: $id) { id identifier title state { name type } }
}]]

-- Cheap change detection: the most recently updated issue under the board's scope filter.
queries.IssuesChanged = [[query IssuesChanged($filter: IssueFilter, $includeArchived: Boolean = false) {
  issues(filter: $filter, first: 1, orderBy: updatedAt, includeArchived: $includeArchived) {
    nodes { id updatedAt }
  }
}]]

-- The organization's project statuses: a plain list (no connection), a few per workspace.
queries.ProjectStatuses = [[query ProjectStatuses {
  organization { projectStatuses { id name type color position archivedAt } }
}]]

-- Archived projects are excluded (`includeArchived` defaults to false). `teams` is capped at 5 per project:
-- the board shows team keys only, and every nested connection multiplies the cost by the page size.
queries.Projects =
	[[query Projects($filter: ProjectFilter, $first: Int = 50, $after: String, $orderBy: PaginationOrderBy = updatedAt) {
  projects(filter: $filter, first: $first, after: $after, orderBy: $orderBy) {
    nodes {
      id name url slugId icon color description priority sortOrder progress health
      startDate targetDate createdAt updatedAt startedAt completedAt canceledAt
      status { id name type color position }
      lead { id name displayName avatarUrl }
      teams(first: 5) { nodes { id key name } }
    }
    pageInfo { hasNextPage endCursor }
  }
}]]

-- Cheap change detection for projects mode: the most recently updated project under the list's filter.
queries.ProjectsChanged = [[query ProjectsChanged($filter: ProjectFilter) {
  projects(filter: $filter, first: 1, orderBy: updatedAt) {
    nodes { id updatedAt }
  }
}]]

-- The project page: the list fields (teams up to 10) plus the overview's document, members, labels and milestones.
-- `Query.project` also returns archived projects. IssueConnection has no count, so milestones carry no issue
-- count: counting would need a nested `issues` page per milestone, multiplying the cost.
queries.Project = [[query Project($id: String!) {
  project(id: $id) {
    id name url slugId icon color description content priority sortOrder progress health healthUpdatedAt
    startDate targetDate createdAt updatedAt startedAt completedAt canceledAt
    status { id name type color position }
    lead { id name displayName avatarUrl }
    teams(first: 10) { nodes { id key name } }
    members(first: 50) { nodes { id name displayName avatarUrl } }
    labels(first: 25) { nodes { id name color isGroup } }
    projectMilestones(first: 50) { nodes { id name status progress targetDate sortOrder } }
  }
}]]

return queries
