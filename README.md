# iredadmin_modules

Customization, packaging, and validation tooling for iRedAdmin/iRedMail deployments.

This repository is a companion layer around upstream software. It is not an official distribution of iRedAdmin, iRedAdmin-Pro, or iRedMail.

## What This Repository Contains

- `modules-setup.sh` to install and wire the customization layer into an existing iRedAdmin deployment
- a distributable overlay archive generated from a customized iRedAdmin codebase
- legal and licensing notes for public redistribution
- supporting documentation around module-oriented features

The customization layer currently covers areas such as:

- extended CRUD flows
- REST API support and smoke-tested workflows
- Amavisd-related admin flows
- iRedAPD-related admin flows
- Fail2ban-related admin flows
- Domain Ownership
- 2FA
- captcha integration
- skin and frontend runtime customization

## Installation

Example:

```bash
ROOT_PATH="/opt/www/iredadmin" \
PATCH_URL="https://raw.githubusercontent.com/cuquet/iredadmin_modules/main/iRedAdmin-patch_20260419_130818.tar.bz2" \
bash <(curl -sSL https://raw.githubusercontent.com/cuquet/iredadmin_modules/main/modules-setup.sh)
```

Adjust paths, versions, and deployment assumptions to your environment before using it on a live server.

`PATCH_URL` is kept as the installer variable name for backward compatibility, even though the published archive is an overlay package rather than a textual patch set.

## Licensing Overview

This repository should be treated as a mixed-licensing repository.

- The repository-level default license is GPL-2.0 because the published overlay archive and parts of the customization layer are derived from iRedAdmin Open Source Edition.
- Original standalone helper scripts, documentation, and similar repository-specific material may also be made available under MIT where explicitly stated.
- This repository does not claim to relicense iRedAdmin-Pro or any third-party software.

Important consequence:

- do not describe the whole repository as MIT-only
- do not assume the overlay archive is a mere patch file
- do not assume every file here is original standalone work

Please read [LEGAL.md](LEGAL.md) and [LICENSES.md](LICENSES.md) before redistributing or repackaging any part of this project.

## Upstream References

- iRedAdmin Open Source Edition: <https://github.com/iredmail/iRedAdmin>
- Upgrade/migration guide: <https://docs.iredmail.org/migrate.or.upgrade.iredadmin.html>
- iRedAdmin-Pro release notes: <https://docs.iredmail.org/iredadmin-pro.releases.html>
- iRedAdmin-Pro pricing/license terms: <https://www.iredmail.org/pricing.html>

## Disclaimer

This repository is not affiliated with or endorsed by the iRedMail project.

Nothing in this repository should be read as legal advice.

## 🤝 Contributions

Contributions are welcome! If you have ideas, improvements or corrections, open an issue or submit a pull request.
[![PayPal - Donate](https://img.shields.io/badge/PayPal-Donate-005EA6?logo=paypal&logoColor=white)](https://www.paypal.me/cuquet74)
