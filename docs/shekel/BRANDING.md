# Shekel Mobility branding

The fork is branded through upstream's MIT branding hooks only: installation config
defaults and the files in `public/`. Nothing under `enterprise/` is changed or enabled, and
`DISABLE_ENTERPRISE` stays `true` (see LOCAL_OIDC_LOGIN.md).

## Logo sources

The logo files are the production ones, copied unchanged from
`shekel-fe/public/images/` (identical in `shekel-admin-fe`). The `shekel-branding` skill
only ships the arrow mark and a "Sheyk" wordmark, not a full Shekel Mobility lockup.

| Chatwoot file | Source | Used for |
|---|---|---|
| `public/brand-assets/logo.svg` (`LOGO`) | `logo-black.svg`: dark `#181918` wordmark | Login page, super admin, light mode |
| `public/brand-assets/logo_dark.svg` (`LOGO_DARK`) | `logo-main.svg`: white wordmark | Same places, dark mode |
| `public/brand-assets/logo_thumbnail.svg` (`LOGO_THUMBNAIL`) | `logo-icon.svg`: the arrow mark | Dashboard sidebar, 512px favicon, widget "Powered by" icon |

The source file names are misleading: `logo-main.svg` is the white-text variant.

The PNG favicons, Android, Apple and MS icons in `public/` are rendered from
`logo_thumbnail.svg` by `docs/shekel/generate_brand_icons.sh`, each at its existing size.
That covers the transparent favicons, Apple icons on the brand's near-black `#181918`
canvas (iOS fills transparency with black), and the unread-badge favicons with a red dot,
as upstream does. Upstream's empty `apple-touch-icon*.png` placeholders are now real
180px icons. `manifest.json` and `browserconfig.xml` use `#181918`.

## Config defaults (`config/installation_config.yml`)

| Key | Value |
|---|---|
| `INSTALLATION_NAME` | `Shailoq by Shekel Mobility` (page title, login heading, every UI string that says "Chatwoot") |
| `BRAND_NAME` | `Shekel Mobility` (emails: "Welcome to …", email footer) |
| `BRAND_URL`, `WIDGET_BRAND_URL` | `https://www.shekelmobility.com` |
| `TERMS_URL` | `https://www.shekelmobility.com/terms-of-use` |
| `PRIVACY_URL` | `https://www.shekelmobility.com/privacy-policy` |

New installations get these on first boot. A database created before this change keeps
Chatwoot's values, because `ConfigLoader` only adds missing keys. Upstream's editor for
them (Super Admin › Settings › Custom Branding) is enterprise-only, so apply them with:

```sh
$DC exec rails bundle exec rails shekel:apply_branding
```

It updates the branding keys only. (`ConfigLoader.new.process(reconcile_only_new: false)`
would also reset every other installation config and feature flag.)

## "Powered by" attribution

Chatwoot's LICENSE is MIT outside `enterprise/`. It requires keeping the copyright and
permission notice in copies of the software (the `LICENSE` file, kept as is), not a
"Powered by" line in the UI.

- **Widget:** `app/javascript/shared/components/Branding.vue` (MIT) shows
  `POWERED_BY` = "Powered by Chatwoot" with "Chatwoot" swapped for `INSTALLATION_NAME` by
  upstream's `replaceInstallationName`, so it now reads "Powered by Shailoq by Shekel
  Mobility", linking to `WIDGET_BRAND_URL`. No code was changed for that.
- **Emails:** the footer in `app/views/layouts/mailer/base.liquid` (MIT) names
  `BRAND_NAME` / `BRAND_URL`.
- Hiding the line entirely is the `disable_branding` premium feature, which lives in
  `enterprise/`. It is not used.

## Not branded

- Product colours: buttons and links keep Chatwoot's blue. Only logos and names changed.
- Any "Chatwoot" text that does not go through `replaceInstallationName` is left as
  upstream has it; it has not been audited page by page.
- `dashboard/assets/images/bubble-logo.svg` (the widget bubble in the inbox widget
  preview) is still Chatwoot's.
