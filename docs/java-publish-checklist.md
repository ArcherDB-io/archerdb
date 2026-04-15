# Java Publish Checklist

Use this checklist before publishing `com.archerdb:archerdb-java` to Maven Central.

This checklist is separate from the main [Release Checklist](release-checklist.md). ArcherDB should already be a clear release `GO` before you use this document.

Publishing to Central is a public release action, not a test step. Do not publish just to verify that Sonatype credentials work. If the answer to "should this exact commit become a public Java release?" is not clearly yes, stop here.

## No-Go Conditions

Do not publish if any of these are true:

- the candidate commit is not the exact commit you intend to expose publicly
- `main` or the chosen release branch is still moving and you have not frozen the release target
- any required GitHub Actions workflow is red or still running on the candidate commit
- parity evidence is stale relative to the candidate commit
- benchmark evidence is stale relative to the candidate commit
- [integration-check-report.md](/home/g/archerdb/integration-check-report.md) or [FINALIZATION_PLAN.md](/home/g/archerdb/FINALIZATION_PLAN.md) still lists a repo-local correctness gap that should block release
- the Java release build does not stage artifacts into `zig-out/dist/java`
- the Java publish preflight does not pass on the release host
- you are missing Central credentials or a usable GPG signing key

## Go Criteria

Only publish when all of these are true:

- the worktree is clean and the candidate commit is selected explicitly
- the candidate commit is green in GitHub Actions for:
  - `CI`
  - `SDK Smoke Tests`
  - `Performance Benchmarks`
- [docs/PARITY.md](/home/g/archerdb/docs/PARITY.md) and `reports/parity.json` are current and green for the candidate commit
- [docs/BENCHMARKS.md](/home/g/archerdb/docs/BENCHMARKS.md) still matches the current checked-in benchmark artifact set
- [integration-check-report.md](/home/g/archerdb/integration-check-report.md) says the only remaining release-evidence work is the external Central rehearsal
- the Java release build stages all four artifacts:
  - `archerdb-java-<version>.jar`
  - `archerdb-java-<version>-sources.jar`
  - `archerdb-java-<version>-javadoc.jar`
  - `archerdb-java-<version>.pom`
- the release host has:
  - Java
  - Maven
  - `MAVEN_USERNAME`
  - `MAVEN_CENTRAL_TOKEN`
  - `MAVEN_GPG_PASSPHRASE`
  - a GPG secret key available to `gpg --list-secret-keys`

## Minimal Pre-Publish Flow

Use the exact release commit, not "whatever is currently on `main`":

```bash
git status -sb
git rev-parse HEAD
```

Build the scripts binary once:

```bash
./zig/zig build scripts:build -j2
```

Set the Java toolchain for the release host:

```bash
export JAVA_HOME=<your-jdk-home>
export PATH="$JAVA_HOME/bin:$PATH"
```

Stage the Java release artifacts:

```bash
./zig-out/bin/scripts release --sha=<commit> --language=java --build
```

Confirm the staged files exist:

```bash
ls -1 zig-out/dist/java
```

Set the publish credentials and signing passphrase:

```bash
export MAVEN_USERNAME=<central-token-username>
export MAVEN_CENTRAL_TOKEN=<central-token-password>
export MAVEN_GPG_PASSPHRASE=<gpg-passphrase>
gpg --list-secret-keys --keyid-format LONG
```

Run the no-side-effects publish preflight:

```bash
./zig-out/bin/scripts release --sha=<commit> --language=java --publish --preflight
```

Only if every earlier gate is green, do the real publish:

```bash
./zig-out/bin/scripts release --sha=<commit> --language=java --publish
```

## Decision Rule

- `GO` means every repo-side gate is green, the candidate commit is intentionally being released, and the publish preflight passes on the release host.
- `NO-GO` means anything else. In that case, do not publish to Maven Central yet.
