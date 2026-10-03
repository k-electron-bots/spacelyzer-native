# Documentation by project type

Start with the reader's task, not a target README length. Keep a useful front page and make deeper material easy to find. No "old README" dumping ground.

| Project type | Front page | Deeper documentation |
|---|---|---|
| Desktop or frontend app | Product purpose, authentic screenshot, install/use path, important limits | Visual tour, task guides, permissions/safety, contributor setup, evidence |
| Hosted SaaS | What works now, who it is for, entry point and honest alpha/availability limits | Onboarding and common tasks, account/data boundaries, operator runbooks, API/integration references, evidence |
| CLI or operator tool | Purpose, installation and one safe example | Synopsis, commands/options/defaults, environment, input/output, exit codes, side effects, retries, troubleshooting |
| Game | Play link, real screen, short control loop | Controls/rules, local run/build, source map and tested limits |
| Library/API | Use case and minimal working example | Public API, compatibility, errors, integration examples and versioning |
| Placeholder/sandbox | Exact purpose and non-goals | Only maintenance instructions the project actually needs |

## Shared rules, different depth
- README is an overview and route map, not a changelog or test transcript.
- User tasks, development references, operational runbooks, specs and verification have distinct homes. Use only categories that the project needs.
- Prefer authentic, inspected screenshots for visual products. Label provenance, fixture/demo data and outdated checkpoints; do not invent product behavior for an attractive tour.
- Separate current behavior from plans, and accepted evidence from source-only changes or simulated controls.
- Preserve important decisions, failures and evidence under descriptive topic names. Delete duplicates and superseded instructions when their useful information has a clear home and traceable history.
- Keep active evidence paths stable. Link to them rather than copying changing results into multiple pages.
- CLI references come from the parser/source, including awkward current behavior. Do not document a planned flag, retry rule or feature as implemented.
- Check links and rendered pages after edits. Visual docs need actual pixel inspection, not only Markdown existence.
- Update docs in the same change as behavior when practical; assign ownership during parallel work. Docs-only edits do not need a product test workflow unless the docs control execution/build behavior.

Personal/read-only repositories need their owner's write permission before implementation. Documentation structure can still be assessed without changing them.
