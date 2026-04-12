# ArcherDB Governance

ArcherDB is maintained as an open-source infrastructure project. This document
describes how project decisions are made, how maintainership works, and what
contributors should expect from the review and release process.

## Project Scope

ArcherDB prioritizes:

- correctness, determinism, and durability
- clear public documentation and reproducible validation
- stable client/CLI behavior for the documented GA surface
- honest release boundaries for experimental or incomplete work

## Decision Making

ArcherDB uses maintainer-led, public decision making.

- Small fixes and documentation changes can go straight to pull requests.
- Medium and large changes should start with a GitHub issue describing the
  problem, scope, and validation plan.
- Breaking changes, protocol changes, storage-format changes, and release-scope
  changes should be discussed in public before implementation.
- Security-sensitive issues follow the private reporting path in
  [SECURITY.md](SECURITY.md).

When there is no disagreement, maintainers use lazy consensus: if the proposal
is technically sound, documented, and reviewed, it can move forward.

## Maintainers

Maintainers are responsible for:

- triaging issues and pull requests
- reviewing and merging changes
- setting release scope and release gates
- enforcing the Code of Conduct
- keeping the project documentation and validation evidence honest

Maintainers may request design discussion, extra tests, or narrower scope before
merging a change.

## Becoming a Maintainer

Maintainer status is based on sustained, high-signal contribution quality rather
than a fixed checklist. Signals include:

- repeated, correct changes across core code or docs
- good review judgment
- careful release and compatibility thinking
- respectful public collaboration
- willingness to maintain code after merge

New maintainers are added by existing maintainers.

## Releases

Releases are cut by maintainers when the current release gates are satisfied.
That includes code health, validation evidence, and documentation truthfulness.

- Experimental surfaces may remain in the repository without being part of the
  current GA release contract.
- Maintainers may defer or de-scope work rather than ship misleading claims.

## Public Project Channels

- Contribution process: [CONTRIBUTING.md](CONTRIBUTING.md)
- Support and issue-routing guidance: [SUPPORT.md](SUPPORT.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Community conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
