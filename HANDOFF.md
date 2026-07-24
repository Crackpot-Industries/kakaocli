# HANDOFF.md — state of this kakaocli checkout, and where to take it

Written 2026-07-24. Read this before touching anything in this
checkout — it explains why we're not on `main`, what's confirmed
working, what's confirmed broken (with exact file:line references),
and what a new session should build next.

This is a **local checkout of a third-party, lightly-maintained
project** ([silver-flight-group/kakaocli](https://github.com/silver-flight-group/kakaocli)),
not our own code — treat everything below as "here's what we've
learned about someone else's codebase," not "here's our
architecture." We got here via Claude Code sessions bootstrapping
KakaoTalk automation for the team (see the `kakaocli-setup` skill at
`~/dev/claude-skills/kakaocli-setup/` for the install path most
people should use — this checkout is for people actually changing
kakaocli's code).

## Where things stand

```
$ git branch --show-current
local/pr20-userid-fix-pinned
$ git log -1 --format='%H %s'
66fee27bf1f1e872765cf6ac3ab3753afdd2d6c4 Fix userId detection: caching, env override, parallel SHA-512 recovery
$ git remote -v
origin  https://github.com/silver-flight-group/kakaocli.git
```

We are **not** on upstream `main`. `main` has a confirmed, unfixed
bug: userId auto-detection brute-forces a SHA-512 pre-image with
only a 10-second timeout, too short for most real Kakao account IDs
(hundreds of millions) — see upstream issues
[#4](https://github.com/silver-flight-group/kakaocli/issues/4) and
[#14](https://github.com/silver-flight-group/kakaocli/issues/14),
both open, no maintainer response. [PR
#20](https://github.com/silver-flight-group/kakaocli/pull/20) by
`altsang` fixes it (parallelizes the search across cores, raises the
budget to 180s, adds an `~/.kakaocli/userid.json` cache and a
`KAKAOCLI_USER_ID` env var override) but is unmerged. We reviewed
the diff (scoped to `DeviceInfo.userId()` resolution only — no
networking, no telemetry — see `Sources/KakaoCore/Database/DeviceInfo.swift`)
and built from the exact commit rather than tracking the live PR
branch, so an upstream force-push can't change what we're running.
Both `local/pr20-userid-fix-pinned` (a branch) and
`pinned-pr20-userid-fix` (a tag) point at `66fee27b` for that reason
— **build from one of those, not `main`**, until this merges
upstream (check first — if it has, the pin can be dropped entirely).

Other unmerged PRs worth knowing about if you're touching auth
further: [#10](https://github.com/silver-flight-group/kakaocli/pull/10)
and [#6](https://github.com/silver-flight-group/kakaocli/pull/6) are
earlier, less complete attempts at the same userId-timeout problem
PR #20 solves — probably superseded, but worth a glance if #20 turns
out to have gaps. [#18](https://github.com/silver-flight-group/kakaocli/pull/18)
("fix: prevent auth hangs and link SQLCipher") is unrelated to
userId and hasn't been investigated.

Building: `brew install sqlcipher` (once), then `swift build -c
release` from this directory. Note `brew install
silver-flight-group/tap/kakaocli` itself does **not** work on a
machine with only Xcode Command Line Tools — the formula demands
full Xcode.app even though the actual build command doesn't need
it (see `Formula/kakaocli.rb` in the tap, or just build from source
as above).

## Confirmed working (as of this checkout)

`status`, `auth`, `chats`, `messages`, `search` — the whole
read-only path. `auth` on a fresh install takes up to ~40-60s the
first time (the actual brute-force search PR #20 fixed), then
instant on repeat runs (cached in `~/.kakaocli/userid.json`). This
was verified end-to-end against a real KakaoTalk-for-Mac install and
account — the fix is real, not just "compiles."

## Confirmed broken: `send`

Two distinct problems, found in the same debugging session:

**1. `--dry-run` tests nothing real.** `Sources/KakaoCLI/Commands/SendCommand.swift`'s
`run()` prints its "would send" message and returns *before* calling
into `KakaoAutomator` at all. It cannot catch any automation
failure, ever, by construction. Don't trust it as a smoke test — if
you're validating a fix, you have to run a real send.

**2. The actual send fails because the Chats-tab click silently
no-ops.** Root cause, confirmed via `kakaocli inspect --depth 6`
against a live KakaoTalk-for-Mac 26.6.1:

`Sources/KakaoCore/Automation/KakaoAutomator.swift:38`:
```swift
if let chatroomsTab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
    _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
    ...
}
```
This searches for an element with **role `AXCheckBox`** and
identifier `"chatrooms"`. On the KakaoTalk build we tested against,
the actual element is a plain **`AXButton`** — confirmed directly
from an `inspect` dump: `[AXButton] title="" id="chatrooms"`. The
role search finds nothing, the `if let` silently no-ops (no error,
no log), KakaoTalk stays on whatever tab it already had open (in our
repro, the "More" panel), and the very next step —
`AXHelpers.chatListTable(mainWindow)` at line 44 — correctly returns
`nil` because the chat list genuinely isn't the rendered view. This
almost certainly explains the long-standing upstream hang bug too
([issue #9](https://github.com/silver-flight-group/kakaocli/issues/9),
"send hangs while --dry-run succeeds" — consistent with automation
stuck waiting on a chat window that can never appear because the tab
was never switched).

**Same bug, second location**: `Sources/KakaoCore/Automation/ChatHarvester.swift:92`
has the identical `role: "AXCheckBox", identifier: "chatrooms"`
pattern — `harvest` likely has the same failure mode. Fix both
together.

**Also found, cosmetic but worth fixing alongside**:
`KakaoAutomator.swift:44-45`'s guard —
```swift
guard let table = AXHelpers.chatListTable(mainWindow) else {
    throw AutomationError.chatNotFound(chatName)
}
```
throws using the raw `chatName` parameter regardless of whether the
caller was doing a `--me` (self-chat) send. Since `chatName` is just
this function's local parameter name — bound to whatever the CLI's
(possibly meaningless placeholder) `<chat>` argument was — a `--me`
send with a placeholder chat argument reports a misleading error
(we saw `Chat '_' not found in the chat list` instead of something
mentioning self-chat). Doesn't affect behavior, just diagnosis; low
priority relative to the actual role-matching bug above.

### The fix (not yet implemented)

`AXHelpers.findFirst(_:role:identifier:)`
(`Sources/KakaoCore/Automation/AXHelpers.swift`) requires an exact
role match:
```swift
public static func findFirst(_ element: AXUIElement, role targetRole: String, identifier targetId: String, ...) -> AXUIElement? {
    if role(element) == targetRole {
        if identifier(element) == targetId { return element }
    }
    ...
}
```
`identifier` alone (`"chatrooms"`) is already a specific, stable
match — the role constraint is the bug, not a safety net. Cleanest
fix: add an overload that matches on identifier only (no role
parameter), and switch both `KakaoAutomator.swift:38` and
`ChatHarvester.swift:92` to it. Alternative, more minimal diff: loosen
the existing overload to accept an array of acceptable roles
(`roles: [String]`) instead of one. Either way, rebuild and validate
with a **real** send (not `--dry-run` — see above) to a self-chat or
a throwaway test contact, plus re-run `harvest` since it shares the
bug.

Once this is fixed, also worth doing: replace the app-wide `if let
... { }` silent-no-op pattern with something that at least logs or
errors when a tab-switch fails, so the *next* UI drift (KakaoTalk
updates constantly) produces a clear error instead of another silent
hang. This class of bug — a hardcoded AX role/identifier that
drifted from what the app currently renders — is exactly what broke
`send`/`harvest` here, and will keep recurring against upstream
KakaoTalk updates for as long as this stays UI-automation-based.

## Extension we want to build: sending images

KakaoTalk's `send` (once fixed above) only sends text —
`Sources/KakaoCLI/Commands/SendCommand.swift` has no attachment
concept at all (`kakaocli send <chat> <message>`, nothing else).
We want to add image sending. Proposed approach, not yet started:

1. **Get the image onto the system pasteboard.** `NSPasteboard`
   (AppKit) supports writing image data directly — read the file,
   construct an `NSImage` (or write raw PNG/TIFF data with the
   right `NSPasteboard.PasteboardType`), `pasteboard.clearContents()`
   then `pasteboard.writeObjects([image])` or the raw-data
   equivalent. This is standard, well-documented Cocoa; no new
   dependency needed beyond what's already linked (this project
   already uses AppKit-adjacent APIs for the live window/automation).
2. **Focus the message input field** — already solved;
   `KakaoAutomator.swift` already does this for text sends
   (`AXHelpers.clickElement(inputField)` / `.focus(inputField)`
   around step 9 of `sendMessage`).
3. **Synthesize Cmd+V.** The Accessibility API doesn't have a
   generic "paste" action, so this needs a real key-event
   simulation via `CGEvent` (`CGEventCreateKeyboardEvent` with the
   Cmd flag set, V key down/up) rather than an AX action — same
   general technique `AXHelpers.pressKey`/`typeText` already use for
   the Enter key and text entry, just needs the Cmd modifier added.
4. **Wait for KakaoTalk to show an attachment preview** before
   sending. Chat apps generally render a thumbnail/preview state
   after a paste before the message is actually composed — sending
   Enter too early might send a blank message or nothing. This step
   needs its own AX investigation (what does the preview state look
   like in the UI tree? `kakaocli inspect --open-chat <name>` after
   manually pasting an image is the way to find out) — don't assume
   the existing Enter-key send path just works unmodified.
5. **CLI surface**: something like `kakaocli send <chat> --image
   <path> [message]` (image with optional caption) rather than a
   wholly separate command, to keep the existing chat-targeting
   logic (`--me`, substring match) shared.

**Sequencing**: fix the Chats-tab role bug above *first*. Building
image support on top of a send path that doesn't reliably reach the
chat window at all would just inherit the same failure — there's no
point debugging "does paste work" while "does send even open the
chat" is still broken.

## Why fork rather than keep pinning

Pinning to a specific upstream commit (what we've done for the
userId fix) is fine for "make an existing PR usable before it
merges." It's the wrong model once we're writing code upstream
doesn't have at all — the Chats-tab fix and image sending are ours,
not something to eventually rebase away. Next session should:

1. Fork `silver-flight-group/kakaocli` for real (GitHub fork, or a
   fresh repo under Crackpot-Industries if a hard fork is preferred
   over a soft one — team's call, not made yet).
2. Push `local/pr20-userid-fix-pinned` (i.e. PR #20's commit) as the
   new base/main branch there, so the userId fix travels with us
   without needing the local-pin dance again.
3. Build the Chats-tab fix and image-sending feature as normal
   commits on top of that fork.
4. Update this checkout's `origin` to point at the fork, and update
   `~/dev/claude-skills/kakaocli-setup/scripts/install_and_verify.sh`
   (currently hardcoded to `github.com/silver-flight-group/kakaocli`
   for both the `git clone` fallback and the PR #20 fetch) to point
   at the fork instead — search that file for
   `silver-flight-group/kakaocli` to find every place that needs
   updating.
5. Consider upstreaming the Chats-tab fix as a PR back to
   `silver-flight-group/kakaocli` regardless of forking — it's a
   small, clearly-scoped bug fix independent of our image-sending
   work, and this project's maintainer might actually merge a
   focused one-line-role-check fix even if the bigger PRs sit
   unreviewed.

## Verifying you haven't broken anything

There's a small test suite (`Tests/KakaoCoreTests/DeviceInfoTests.swift`,
`KeyDerivationTests.swift` — both added by PR #20, run with `swift
test`), but it only covers userId/key-derivation logic. Nothing
covers the Automation layer (`AXHelpers`, `KakaoAutomator`,
`ChatHarvester`) — the send/harvest fix above and any image-sending
work have no automated coverage and need to stay manually verified:

```sh
swift build -c release
.build/release/kakaocli status                 # should show account/db info
.build/release/kakaocli auth                    # should decrypt cleanly (cached, near-instant)
.build/release/kakaocli chats --limit 10        # should list real chats
.build/release/kakaocli send --me _ "test" --dry-run   # meaningless per above, but shouldn't crash
.build/release/kakaocli send --me _ "test"      # THE REAL TEST for any send/tab-click fix
.build/release/kakaocli harvest --dry-run       # sanity check before a real harvest run
```

Full Disk Access and Accessibility permissions need to already be
granted to whatever terminal is running these (System Settings >
Privacy & Security) — see the `kakaocli-setup` skill if starting
from scratch on a new machine.
