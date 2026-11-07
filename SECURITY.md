# Security policy

Headroom can delete files, so we treat safety and security bugs as the most important kind.

## Supported versions

Only the [latest release](https://github.com/medaimane/headroom/releases/latest) gets fixes.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub's [private vulnerability reporting](https://github.com/medaimane/headroom/security/advisories/new).

Include what you found, how to reproduce it, and which version and macOS release you used. You'll get a reply within 7 days. Once a fix is out, you'll be credited in the release notes unless you'd rather not be.

## What counts

Report it privately if Headroom could, for example:

- delete or change anything outside its allow-listed cache locations, or follow a symlink out of them;
- touch code in a git working tree, uncommitted work or a `.env*.local` file, or remove a `node_modules` that isn't ignored, belongs to a worktree with uncommitted or unpushed work, or is in use;
- delete without the user's confirmation, or while dry run is on;
- stop a process without confirmation;
- read, show or store the contents of logs, env files, configs or command lines;
- make a network call, or run anything with elevated rights without the standard macOS prompt.

Ordinary bugs (wrong sizes, crashes, layout problems) can go in a normal [issue](https://github.com/medaimane/headroom/issues/new/choose).
