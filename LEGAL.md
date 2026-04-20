# Legal and Redistribution Notice

This document is a practical repository notice. It is not legal advice.

## Positioning

This repository should be presented as a customization, automation, packaging, and validation layer around iRedAdmin/iRedMail deployments.

It should not be presented as:

- the official iRedAdmin repository
- an official iRedMail distribution
- a public redistribution of iRedAdmin-Pro

## What Is Being Published Here

This repository currently includes a distributable overlay archive generated from a customized iRedAdmin codebase, together with installer logic and repository-specific helper material.

That matters because an overlay archive containing copied or modified upstream files is not the same thing as a repository containing only original scripts or textual patch files.

## Upstream Software

According to official upstream materials:

- iRedAdmin Open Source Edition is distributed by the iRedMail project under GPL-2.0.
- iRedAdmin-Pro is a separate commercial product with vendor-controlled redistribution terms.

References:

- <https://github.com/iredmail/iRedAdmin>
- <https://docs.iredmail.org/migrate.or.upgrade.iredadmin.html>
- <https://docs.iredmail.org/iredadmin-pro.releases.html>
- <https://www.iredmail.org/pricing.html>

## Practical Licensing Position

The prudent public position for this repository is:

- treat upstream-derived overlay content as GPL-2.0-derived
- treat original standalone repository material as separately licensable only where explicitly stated
- do not describe the whole repository as MIT-only

## What We Could Verify

Repository inspection shows that at least part of the published overlay content is not purely original standalone work:

- some files are identical to files from the public iRedAdmin Open Source Edition
- some files are modified derivatives of public iRedAdmin Open Source Edition files

Because of that, a blanket statement such as "all distributed code is original work" would be too strong.

## Lower-Risk Publication Model

The lower-risk publication model remains:

- original scripts
- original documentation
- original tests
- patch files and diffs
- build/setup instructions

## Higher-Risk Publication Model

The higher-risk publication model includes:

- bundled upstream code overlays
- vendor release archives
- generated bundles that embed code you may not redistribute
- statements claiming permissive relicensing of derivative upstream code

## Public Checklist

Before publishing updates, review whether the repository contains:

- copied upstream source files
- modified upstream source files
- generated assets built from upstream-derived code
- headers or provenance notes that indicate third-party ownership
- documentation that overstates relicensing rights

If certainty is important for broad redistribution, commercial reuse, or reselling, obtain qualified legal review first.

## No Warranty

To the extent permitted by law, the materials in this repository are provided "as is", without warranty of any kind.
