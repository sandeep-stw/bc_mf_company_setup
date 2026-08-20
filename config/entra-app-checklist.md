# BCM-010 — Configure Microsoft Entra application

Use this checklist for service-to-service (client credentials) access to Business Central. Declarative settings live in `config/entra-app.json`. To automate Entra registration when Azure CLI is available, run `scripts/Register-BCEntraApp.ps1`.

## 1. Create app registration

1. Sign in to the [Microsoft Entra admin center](https://entra.microsoft.com).
2. Go to **App registrations** → **New registration**.
3. Name: `Apex Manufacturing BC Automation` (or the `displayName` in `entra-app.json`).
4. Supported account types: **Accounts in this organizational directory only** (single tenant).
5. Redirect URI (optional, Web): `https://businesscentral.dynamics.com/OAuthLanding.htm` — required only if you grant consent from the Business Central web client.
6. Register the app and copy:
   - **Application (client) ID** → `BC_CLIENT_ID`
   - **Directory (tenant) ID** → `BC_TENANT_ID`

## 2. Configure Business Central API access

1. Open the app → **API permissions** → **Add a permission**.
2. Choose **Microsoft APIs** → **Dynamics 365 Business Central**.
3. Select **Application permissions** and add:
   - `API.ReadWrite.All` — APIs and web services
   - `Automation.ReadWrite.All` — automation / company setup APIs
4. Click **Add permissions**.
5. Prefer **Grant admin consent for \<tenant\>** here (or grant consent later from Business Central).

Resource app ID (Dynamics 365 Business Central): `996def3d-b36c-4153-8607-a6fd3c01b89f`.

## 3. Create client credential

1. Open **Certificates & secrets** → **New client secret**.
2. Description: `apex-bc-automation` (or `clientSecret.displayName` in `entra-app.json`).
3. Choose an expiry (default in config: 24 months).
4. Click **Add** and immediately copy the secret **Value** → `BC_CLIENT_SECRET`.
5. Never commit the secret. Store it only in the local gitignored `.env`.

## 4. Assign required Business Central permissions

Entra API permissions alone are not enough. Register the app inside Business Central:

1. In Business Central, search for **Microsoft Entra Applications**.
2. **New** → set **Client ID** to the Application (client) ID.
3. Set **Description** (for example `Apex Manufacturing automation`).
4. Set **State** to **Enabled**.
5. Assign permission sets (do **not** use `SUPER`):
   - `D365 AUTOMATION`
   - `EXTEN. MGT. - ADMIN`
6. If admin consent was not granted in Entra, select **Grant Consent** on the card (requires the redirect URI above).

## 5. Wire local environment

```bash
cp .env.example .env
```

Fill at least:

| Variable | Source |
| --- | --- |
| `BC_TENANT_ID` | Entra Directory (tenant) ID |
| `BC_CLIENT_ID` | Entra Application (client) ID |
| `BC_CLIENT_SECRET` | Client secret value |
| `BC_ENVIRONMENT_NAME` | BC environment name (for example `sandbox`) |
| `BC_API_BASE_URL` | `https://api.businesscentral.dynamics.com/v2.0/{tenantId}/{environmentName}` |

`BC_COMPANY_ID` is filled by `pwsh -File scripts/Get-BCCompanies.ps1 -UpdateEnv` (BCM-013).

## Verify

After BCM-011 is available:

```powershell
pwsh -File scripts/Get-BCAccessToken.ps1
```

A non-empty access token means Entra app registration, secret, and admin consent are working. Business Central object permissions are confirmed when company/API calls succeed (BCM-014).
