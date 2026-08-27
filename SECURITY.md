# Reporting a vulnerability

**Do not open a public issue for a security problem.** Send it to
**contact@ideoa.co.uk** instead.

A public issue is a working exploit handed to everybody who reads the
repository, including everybody currently running the build it affects. That is
true even for a report that looks minor: the value of a finding is decided after
it is understood, not before, and it cannot be un-published afterwards.

This repository is the client. The protocol, the relay and the mailbox server
live in the Rotelyx protocol repository and carry their own `SECURITY.md`, with
the same address and the same terms. Send it here if you are unsure which side a
finding falls on. Working that out is our job, not yours.

## What to send

Whatever you have. A partial report that arrives is worth more than a complete
one that does not, so none of this is a requirement:

- What breaks, and what an attacker gets out of it.
- Where it is: a file and a line, a screen, or a description of the flow.
- How to reproduce it. A failing test, a screen recording, or the steps.
- Which build you were looking at: a commit hash, or the version the app shows.
- Which platform. Web, Android, desktop and iOS do not share an engine binding,
  and a finding on one is often not a finding on another.
- Whether anybody else has been told, and whether you intend to publish.

If you want the report encrypted, say so in a first message with nothing
sensitive in it and we will arrange a key.

## What happens next

- We acknowledge receipt within **three working days**. If you do not hear back
  in that time, assume the mail went astray and send it again.
- We tell you what we think it is, and whether we agree with your assessment,
  within **ten working days**.
- We fix it, and we say publicly what was wrong once a fix is out. The write-up
  names the finder unless you ask us not to.

There is no bug bounty. This is a pre-release project run by a small team and we
would rather be honest about that than imply a payment that does not exist.

## What is in scope

The Flutter client and everything it ships: the vault, the stored conversations,
the platform bindings to the engine, the web build and its Content-Security
-Policy, and the Android, desktop and iOS packaging.

Two things are worth reporting even though they are not code in this tree: an
engine defect that this client drives into a user's hands, and a stale shipped
artifact. A source fix that never reached the bundled WebAssembly or the packaged
native library is a live vulnerability regardless of what the source says, and it
has happened here before.

## What is not a finding

- **That the project has not been independently audited.** It says so in the
  README. It is a stated condition, not a discovery.
- **That a conversation nobody compared is unverified.** The app asks once, with
  the digits on screen, and then says so plainly wherever the conversation is
  shown rather than recording a comparison that did not happen. Making it refuse
  the first message is a decision we have taken and can revisit; an argument for
  it is welcome, and it is not a vulnerability report.
- **Anything listed as unsolved in the protocol threat model.** A compromised
  device rendering plaintext, a global passive adversary correlating flows. A new
  attack *within* one of those classes may still be worth reporting, and a way to
  solve one of them certainly is.

## Disclosure

We ask for ninety days before publication, and we will move faster than that
whenever we can. If we go quiet, or if we are still arguing about severity after
ninety days, publish. A deadline that only the reporter honours is not a
deadline, and a project that hides behind one deserves the write-up it gets.
