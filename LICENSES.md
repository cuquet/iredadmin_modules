# Licensing Overview

This repository should be treated as a mixed-licensing repository.

## Summary

- The repository-level default license is GPL-2.0.
- The overlay archive published in this repository should be treated as GPL-2.0-derived because it contains upstream-derived iRedAdmin Open Source Edition material.
- Original standalone scripts, documentation, and similar repository-specific material may also be made available under MIT where explicitly stated.

This document is a practical repository notice, not legal advice.

## Why The Repository Default Is GPL-2.0

The repository includes a distributable archive generated from a customized iRedAdmin codebase rather than only textual patches.

Inspection of the published overlay content shows that it includes:

- files identical to public iRedAdmin Open Source Edition files
- files modified from public iRedAdmin Open Source Edition files

Because of that, a blanket MIT-only license for the full repository would be misleading.

## GPL Bucket

The GPL-2.0 license in [LICENSE](LICENSE) applies by default to upstream-derived material and repository content distributed as part of the overlay layer, including in general:

- published overlay archives
- upstream-derived controllers
- upstream-derived libraries
- upstream-derived templates
- upstream-derived static/runtime assets

## MIT Bucket

The MIT license in [LICENSE-MIT](LICENSE-MIT) is intended only for original standalone repository material where that grant is explicitly appropriate, for example:

- original standalone helper scripts
- original standalone documentation
- original standalone tests
- original standalone automation helpers

Recommended practice:

- keep original standalone material clearly separated from upstream-derived material
- add short file headers when you want a file to be unmistakably MIT-licensed
- avoid mixing MIT-only original code and upstream-derived GPL code in the same file

## Public Redistribution Guidance

If you redistribute this repository or parts of it:

- do not describe the whole repository as MIT-only
- do not assume every file is original work
- do not assume the overlay archive is equivalent to a textual patch set

## Upstream References

- iRedAdmin Open Source Edition: <https://github.com/iredmail/iRedAdmin>
- Upgrade/migration guide: <https://docs.iredmail.org/migrate.or.upgrade.iredadmin.html>
- iRedAdmin-Pro release notes: <https://docs.iredmail.org/iredadmin-pro.releases.html>
- iRedAdmin-Pro pricing/license terms: <https://www.iredmail.org/pricing.html>
