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

The script calls the standard `companies` API, matches `Apex Furniture Manufacturing Pvt. Ltd.` (override with `BC_COMPANY_NAME` or `-Name`), and prints the company GUID. `-UpdateEnv` writes `BC_COMPANY_ID` in `.env`. Offline tests: `pwsh -File scripts/Get-BCCompanies.Tests.ps1`.

8. Create the Apex demo company in the **sandbox** environment (BCM-040):

```powershell
pwsh -File scripts/New-BCApexCompany.ps1 -UpdateEnv
```

This is idempotent. It uses the Microsoft automation API (`automationCompanies`) with an existing seed company (typically CRONUS). Identity is `APEX` / `Apex Furniture Manufacturing Pvt. Ltd.` from [`config/apex-company.json`](config/apex-company.json). The new company is empty until later setup (BCM-041+). Offline tests: `pwsh -File scripts/New-BCApexCompany.Tests.ps1`.
