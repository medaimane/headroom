<!-- Feature and fix pull requests target `dev`. Only `release/*` and `hotfix/*` branches target `main`. -->

## What and why

<!-- What does this change, and why? Link the issue, e.g. "Closes #12". -->

## How I tested it

<!-- Commands you ran and what you checked in the app. Never test clean-ups on your real home folder: use a fixture home or dry run. -->

## Checklist

- [ ] `make test` passes, and new behaviour has tests
- [ ] No new compiler warnings
- [ ] Docs updated if users will notice (`docs/guide/index.html`, README)
- [ ] A line under **Unreleased** in `CHANGELOG.md` if users will notice

## Safety

- [ ] Nothing is deleted or changed without the user's review and click
- [ ] Any removal goes through `PathGuard` and stays inside allow-listed locations
- [ ] Doesn't touch git working trees, uncommitted work or `.env*.local` files
- [ ] Doesn't stop processes without confirmation
- [ ] Doesn't read or show the contents of logs, env files, configs or command lines
- [ ] No network calls, telemetry or hidden sudo
- [ ] The action is recorded in History with how to undo it (if it changes anything)
