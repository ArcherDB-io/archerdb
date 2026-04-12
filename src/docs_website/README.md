# docs.archerdb.com

Documentation generator for <docs.archerdb.com>. Static website is generated via `zig build`
and can be pushed to a public docs repository, which is then hosted on GitHub
Pages. The release script defaults to `ArcherDB-io/docs` and can be overridden
with `ARCHERDB_DOCS_REPO`.

The website can also be build from the repository root via `./zig/zig build docs`.

Overview of the build process:

* Inputs are Markdown files from `/docs` and `/src/clients/$lang/README.md`.
* Links are checked by `./src/file_checker.zig`.
* Spelling is checked by vale. A list of accepted words is maintained in
  `./styles/config/vocabularies/docs/accept.txt`.
* Outputs are static HTML files in the `./zig-out` directory.

This process is triggered by `ci.zig` in our merge queue (mostly to detect
broken links) and by `release.zig` to push the rendered docs to the configured
public docs repository.
