# Features added by the module installation

The module setup extends stock iRedAdmin with the following capabilities:

* REST API endpoints and smoke-tested API workflows.
* Extended CRUD flows for domains, users, admins, and mailing lists.
* Amavisd integration:
  * quarantine listing and raw message inspection
  * release/delete actions
  * logging and policy lookup related views
* iRedAPD integration:
  * greylisting
  * spam policy management
  * white/black lists
  * throttling
* Fail2ban integration:
  * jail management
  * banned IP management
  * SQL/runtime helpers for canonical and lab environments
* Domain Ownership workflow and verification UI.
* 2FA support in UI and API flows.
* Captcha integration through module setup:
  * Friendly Captcha
  * Google reCAPTCHA v2 Checkbox
* Cleanup cron/runtime helpers installed by `modules-setup.sh`.
* Session-level theme and skin switching for newer skins.

## Local skins

Available skins are configured in `custom_settings.py`.

* `SKIN = "classic"`: legacy skin kept as a stable baseline and fallback.
* `SKIN = "codyframe"`: current stable canonical skin for day-to-day administration.
* `SKIN = "tailwind"`: actively evolved canonical skin with the newest UI/runtime work.
* `SKIN = "bootstrap"`: experimental skin; still very green and not a production target yet.
* Runtime switch (per session, no restart): `/switch/skin/<skin>?next=/dashboard`

# Instalation

```bash
    ROOT_PATH="/opt/www/iredadmin" PATCH_URL="https://raw.githubusercontent.com/cuquet/iredadmin_modules/main/iRedAdmin-patch_20260419_130818.tar.bz2" bash <(curl -sSL https://raw.githubusercontent.com/cuquet/iredadmin_modules/main/modules_setup.sh)
```

# 📦 License
This project is offered under the license [MIT](https://choosealicense.com/licenses/mit/). You can freely modify, distribute and integrate it.

# 🤝 Contribucions
Contributions are welcome! If you have ideas, improvements or corrections, open an issue or submit a pull request.
[![PayPal - Donate](https://img.shields.io/badge/PayPal-Donate-005EA6?logo=paypal&logoColor=white)](https://www.paypal.me/cuquet74)
