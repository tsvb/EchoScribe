# Security Policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub:
[**Report a vulnerability**](https://github.com/tsvb/EchoScribe/security/advisories/new)
(also reachable from the repository's **Security** tab).

Please don't open a public issue for a security problem — public issues are the right
place for everything else.

EchoScribe is maintained by one person as a side project, so there's no formal SLA and
no bug bounty. Expect an acknowledgement within about a week. If a report is valid,
the fix ships in the next release and you'll be credited in the advisory unless you'd
rather not be.

Useful things to include: the affected component (macOS app or web prototype), the
version or commit, what an attacker gains, and the smallest set of steps that shows it.

## Supported versions

| Version | Supported |
|---|---|
| 2026.8 (latest release) | ✅ |
| Older / unreleased builds from `main` | Best effort |

Fixes land on `main` and go out in the next signed release. There are no long-term
support branches.

## Scope

**In scope**

- The macOS app in [`macos-native/`](macos-native/) — this is the primary product.
  Of particular interest: anything that exposes a cloud API key (Gemini or OpenAI)
  from the Keychain
  ([`KeychainStore.swift`](macos-native/KeychainStore.swift)), anything that reads or
  destroys meeting audio and transcripts outside
  [`MeetingStore`](macos-native/MeetingStore.swift), and anything that achieves code
  execution.
- The legacy web prototype in [`public/`](public/) — lower priority, but a way to
  execute script in the page (and so steal the API key) is a real finding.
- The release pipeline in [`macos-native/scripts/release.sh`](macos-native/scripts/release.sh)
  — signing, notarization, or anything affecting what ends up in a shipped DMG.

**Out of scope — deliberate design decisions, already documented**

- **The App Sandbox is intentionally off.** Enabling it would relocate
  `~/Library/Application Support/EchoScribe/` into a container and hide existing
  meeting history. Hardened Runtime is applied at signing time.
- **The web prototype keeps its API key in browser `localStorage`.** That is the
  documented tradeoff of a keyless-server prototype. A report that *only* restates this
  isn't a vulnerability — but any way to *read* that key that the design doesn't already
  imply (script injection, for example) very much is.
- **`server.js` is a local development server**, not a hosted service. It serves static
  files so a browser can load the prototype. Findings that require deploying it to the
  public internet are out of scope.
- **Choosing a cloud engine (Gemini or OpenAI) uploads audio to that provider** under
  your own API key. This is stated in the README and in the app; it's the point of
  those engines, not a leak. The Apple on-device engine sends nothing off the machine.

## What EchoScribe does with your data

Meetings live only on your Mac, in `~/Library/Application Support/EchoScribe/` — a
`meetings.json` index plus one `.m4a` per meeting. Deleting a meeting in the app deletes
its audio. Nothing is uploaded anywhere unless you pick a cloud engine (Gemini or
OpenAI), and the project has no servers, no telemetry, and no analytics.
