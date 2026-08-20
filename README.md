# bc_mf_company_setup

Apex Manufacturing demo setup for Dynamics 365 Business Central.

## Prerequisites

1. Copy `.env.example` to `.env` (gitignored).
2. Configure the Microsoft Entra application for Business Central S2S access:
   - Checklist: [`config/entra-app-checklist.md`](config/entra-app-checklist.md)
   - Declarative permissions: [`config/entra-app.json`](config/entra-app.json)
   - Optional automation (Azure CLI):

```powershell
az login --allow-no-subscriptions
pwsh -File scripts/Register-BCEntraApp.ps1 -GrantAdminConsent
```

3. Paste the printed `BC_TENANT_ID`, `BC_CLIENT_ID`, and `BC_CLIENT_SECRET` into `.env`.
4. In Business Central, open **Microsoft Entra Applications**, enable the app, and assign `D365 AUTOMATION` and `EXTEN. MGT. - ADMIN` (not `SUPER`).
5. Acquire a Business Central access token (client credentials):

```powershell
. ./scripts/Get-BCAccessToken.ps1
$token = Get-BCAccessToken
```
