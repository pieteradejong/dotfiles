# My Software Development Process

> Purpose: Documenting my development process.  
> Audience: Myself. For my own future reference.

## Documentation

* Utilize auto-documentation wherever possible, e.g. `FastAPI`.
* `README` describes design choices. Includes colored badges for build status, tests passing etc.
* In code: utilize auto-documentation, especially for APIs.
* Describe design choices including alternatives and reasoning.

## Coding Style and Practices

* Always as strictly typed as possible, even in Python where type annotations are not enforced during compilation to bytecode. They are still useful for tools such as IDEs and linters, and for code readability.
* Always as much pre-defined and pre-allocated as possible. For example, if we know a list/array will have `exactly N`, or `at most N` elements, this should be made clear at time of declaration or assignment.

## Version Management

`git` - standard version control workflow.

## Testing

### Python: Local Development Workflow

Write code → lint using Ruff → Run all tests (e.g. pytest) → commit

* Local: run `ruff`, `black`, `pytest`. Include each in `pre-commit`.
* GitHub action (as personal CI): run the same.

### TypeScript/JavaScript

* Local: run `eslint` for syntax/style errors, `prettier` for style issues.
* GitHub action (as personal CI): run the same.

## Profiling

### Python: Database, Network, CPU

TODO: research integration of profiling tools into workflow.

## Deployment

Local → Remote → Production

## README Personal Template/Guidelines

* Descriptive title
* Screenshot if possible, or a diagram of architecture / code flow
* If applicable, a note about project status (alpha, beta, production ready, just a script, etc.)
* Tech stack with links
  * Relevant URLs if "based on" other projects
* Feature roadmap

### Useful Emojis / Graphics

- [x] Feature completed
- [-] Feature in progress
- [ ] Feature not started
- ✅ - "completed"
- 🕐 or ✏️ - "work in progress"
- ☐ - "not yet started"
