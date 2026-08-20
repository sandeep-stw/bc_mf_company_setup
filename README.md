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

6. Call Business Central APIs through the helper module (BCM-012):

```powershell
Import-Module ./scripts/BCApi.psd1

$companies = Invoke-BCApiGet -Path 'companies' -AllPages
$items = Invoke-BCApiGet -Path 'items' -CompanyId $env:BC_COMPANY_ID -Top 20
Invoke-BCApiPost -Path 'items' -CompanyId $env:BC_COMPANY_ID -Body @{ displayName = 'Example' }
```

`Invoke-BCApiGet`, `Invoke-BCApiPost`, `Invoke-BCApiPatch`, and `Invoke-BCApiDelete` authenticate with `Get-BCAccessToken`, follow OData `@odata.nextLink` pagination (`-AllPages`), log method/URL/status (never tokens), and surface Business Central error codes. Custom manufacturing APIs use `-ApiPublisher apex -ApiGroup manufacturing`. Offline tests: `pwsh -File scripts/BCApi.Tests.ps1`.

7. Resolve the Apex demo company ID (BCM-013):

```powershell
pwsh -File scripts/Get-BCCompanies.ps1
pwsh -File scripts/Get-BCCompanies.ps1 -List
pwsh -File scripts/Get-BCCompanies.ps1 -UpdateEnv
```

The script calls the standard `companies` API, matches `Apex Manufacturing` (override with `BC_COMPANY_NAME` or `-Name`), and prints the company GUID. `-UpdateEnv` writes `BC_COMPANY_ID` in `.env`. Offline tests: `pwsh -File scripts/Get-BCCompanies.Tests.ps1`.
