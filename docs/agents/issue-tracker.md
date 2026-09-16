# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- **Close**: `gh issue close <number> --comment "..."`.

Infer the repository from `git remote -v`; `gh` does this automatically inside the clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and PRs. Resolve a bare `#42` with `gh pr view 42` and fall back to `gh issue view 42`.

## Skill operations

When a skill says to publish to the issue tracker, create a GitHub issue. When it says to fetch a ticket, run `gh issue view <number> --comments`.

## Wayfinding operations

Wayfinder uses one issue labelled `wayfinder:map` as the map and GitHub child issues as decision tickets.

- **Map**: create one issue labelled `wayfinder:map`. Its body holds Destination, Notes, Decisions so far, Not yet specified and Out of scope.
- **Child ticket**: link an issue to the map through GitHub's sub-issues endpoint. If sub-issues are unavailable, add the child to a task list in the map and put `Part of #<map>` at the top of the child. Apply one of `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling` or `wayfinder:task`.
- **Blocking**: prefer GitHub's native issue dependencies. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-database-id>`, using the numeric database ID from `gh api repos/<owner>/<repo>/issues/<number> --jq .id`. If dependencies are unavailable, use `Blocked by: #<number>` in the child body.
- **Frontier**: consider the map's open children in map order. Exclude tickets with an open blocker or an assignee. The first remaining ticket is next.
- **Claim**: assign the ticket to the driving developer before work begins.
- **Resolve**: post the answer as a resolution comment, close the ticket, then append a one-line gist and link to the map's Decisions so far.
