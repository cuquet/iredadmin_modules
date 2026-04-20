# Public Repository Legal Notice

This document is a practical notice for publishing a repository that contains helper material around iRedAdmin/iRedMail deployments. It is not legal advice.

## Positioning

This repository should be presented as a customization, automation, patching, and validation layer.

It should not be presented as:

- the official iRedAdmin repository
- an official iRedMail distribution
- a public redistribution of iRedAdmin-Pro

## Upstream Software

According to official upstream sources:

- iRedAdmin Open Source Edition is distributed by the iRedMail project under GPL-2.0.
- iRedAdmin-Pro is a commercial product with vendor-controlled redistribution terms.

References:

- <https://github.com/iredmail/iRedAdmin>
- <https://docs.iredmail.org/migrate.or.upgrade.iredadmin.html>
- <https://docs.iredmail.org/iredadmin-pro.releases.html>
- <https://www.iredmail.org/pricing.html>

## What Is Usually Safer To Publish

The lower-risk publication model is:

- original scripts
- original documentation
- original tests
- patch files and diffs
- setup/build instructions

## What Is Usually Riskier To Publish

The higher-risk publication model is:

- upstream proprietary files
- vendor release archives
- generated bundles that embed third-party code you may not redistribute
- modified copies of commercial upstream code
- statements claiming permissive relicensing of files that may remain derivative works

## Practical Checklist Before Publishing

Before making a public release, review the repository for:

- copied upstream source files
- comments or headers indicating commercial/proprietary origin
- packaged tarballs or zip files
- built assets produced from code with unclear redistribution status
- README text that overstates ownership or licensing rights

If in doubt, remove the questionable artifact and publish:

- a patch
- a diff
- a setup script
- a build recipe
- a note instructing users to start from officially obtained upstream software

## Suggested Public Claim

A cautious public description is:

> This repository contains original helper scripts, documentation, tests, and patch-oriented customization used with iRedAdmin/iRedMail deployments. Upstream software must be obtained from official sources and remains subject to its own license terms.

## No Warranty

To the extent permitted by law, the materials in this repository are provided "as is", without warranty of any kind.
