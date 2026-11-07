# Contributing to Headroom

Thanks for helping. Headroom is a small, careful app: it runs on people's work Macs and can delete files, so safety comes before features. This guide covers how to set up, what we expect in a change, and how to send it.

By taking part you agree to follow the [code of conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Ways to help

- **Report a bug** or **suggest a feature** with the [issue forms](https://github.com/medaimane/headroom/issues/new/choose).
- **Add a cache location** your tools use (see [Adding a cache location](#adding-a-cache-location)).
- **Teach Headroom a tool** it doesn't recognise yet, in `ProcessCategorizer.swift`.
- **Improve the docs**: the website and guide are plain HTML in [`docs/`](docs/).

For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Set up

You need macOS 14 or later and Xcode 16 or later (Swift 6). There are no other dependencies.

```bash
git clone https://github.com/medaimane/headroom.git
cd headroom
make test        # unit tests
make debug-app   # debug build of build/Headroom.app; clean-ups are always a dry run
open build/Headroom.app
```

Other useful targets:

| Command | What it does |
|---|---|
| `make cli ARGS=storage` | Read-only reports: `health`, `processes`, `storage`, `devices`, `worktrees`, `plan` |
| `make app` | Release build |
| `make site` | Serves the website at http://localhost:8765 |
| `make icon` | Re-renders the app icon from `docs/assets/icon.svg` |

You can also open `Package.swift` in Xcode.

## Project layout

```
Sources/HeadroomCore     logic, no UI: metrics, processes, storage catalog, path guard, planner, executors, git, records
Sources/Headroom         SwiftUI app: menu bar, window, settings
Sources/headroom-cli     read-only command-line reports
Tests/HeadroomCoreTests  Swift Testing; clean-ups run only against fixture folders in $TMPDIR
docs/                    website and guide (GitHub Pages), with logo files in docs/assets
scripts/                 app bundle, icon and release scripts
```

Keep logic in `HeadroomCore` where it can be tested, and keep the views thin.

## Safety rules for every change

These are the promises Headroom makes to its users. A change that weakens one won't be merged.

1. **Nothing is deleted without the user's click**, and nothing is deleted automatically or on a schedule.
2. **Only allow-listed locations are cleaned.** Every removal goes through `PathGuard`, both when the plan is made and right before removal.
3. **Never touch the user's work:** git working trees, uncommitted changes, `.env*.local` files, or worktrees with unpushed commits.
4. **Never stop a process** (agent sessions, simulators, emulators, dev servers) without the user's confirmation.
5. **Never read or show the contents** of logs, env files or configs. Show sizes and locations only. Process command lines may be used to recognise a tool but are never stored or shown.
6. **No network calls and no telemetry.** Any future network feature has to be opt-in and visible.
7. **No hidden sudo,** and never change security settings (SIP, Gatekeeper, FileVault, firewall, XProtect, updates).
8. **Every action is recorded in History** with how to undo it.

### Developing safely

- **Never run live clean-ups on your own Mac while developing.** Debug builds force dry run. To exercise real deletions, point the app or tests at a fixture home in a temporary folder with `HEADROOM_HOME`.
- Tests that remove files must use the fixtures in `Tests/HeadroomCoreTests/Fixture.swift`, never your real home folder.
- Git commands must stay read-only (`--no-optional-locks`, no fetch, commit or checkout).

## Adding a cache location

1. Add a `CatalogEntry` to `Sources/HeadroomCore/Storage/StorageCatalog.swift` with:
   - a stable `id` (for example `bun.cache`),
   - the folder, relative to home (or a `$TMPDIR` prefix),
   - a `rebuildNote` that says plainly what happens after cleaning,
   - the processes that should block cleaning while they run.
2. Only add a location if its tool **rebuilds it by itself**. Anything holding user data, settings or state isn't a cache.
3. Add a test for any new guard or blocking rule.
4. Add the location to the cache catalog table in `docs/guide/index.html`.

## Code style

- Swift 6 with strict concurrency; no new compiler warnings.
- Follow the style of the surrounding code: small types, clear names, `// MARK:` sections.
- Comment the *why*, not the *what*.
- No third-party dependencies without discussing it in an issue first.
- UI text is plain and calm: say what happens, how big it is and how to undo it.

## Tests

```bash
make test
```

All tests must pass, and new behaviour needs tests. Safety rules (guards, planners, executors) need tests that prove the unsafe case is refused, not only that the safe case works. CI runs the same tests on every pull request.

## Branches

Headroom uses a small git-flow model. `main` only ever holds released code, which is why the website (published from `main`) always matches the latest download.

| Branch | Cut from | Merges into | What it's for |
|---|---|---|---|
| `main` | n/a | n/a | Released code only. Every release is a signed tag `vX.Y.Z` on `main`. |
| `dev` | `main` | `release/*` | Day-to-day integration. The default branch; all feature and fix pull requests target it. |
| `feat/<topic>`, `fix/<topic>`, `docs/<topic>` | `dev` | `dev` | One change each, e.g. `feat/bun-cache` or `fix/derived-data-size`. |
| `release/X.Y.Z` | `dev` | `main`, then `main` into `dev` | Preparing a release: version, changelog, site label. No new features. |
| `hotfix/X.Y.Z` | `main` | `main`, then `main` into `dev` | Urgent fixes to the latest release. |

How changes are merged:

- **Into `dev`:** squash and merge, so each pull request is one commit.
- **`release/*` and `hotfix/*` into `main`:** a merge commit (not squash), so `main` can be merged back into `dev` cleanly.
- **After every release or hotfix,** `main` is merged back into `dev`.

`main` and `dev` only change through pull requests with CI passing.

## Sending a change

1. Fork the repository and create a branch from `dev` (for example `feat/bun-cache`).
2. Keep each pull request to one change, and include tests and docs.
3. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything users will notice.
4. Write commit messages in the imperative ("Add Bun cache location"), with a body explaining why when it isn't obvious.
5. Open the pull request **against `dev`** and fill in the template, including the safety checklist.

## Releases

Releases and hotfixes are cut by the maintainer, following the branches above. The full steps are in the guide's [Releasing](https://medaimane.github.io/headroom/guide/#releasing) section.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
