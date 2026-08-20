@{
    RootModule        = 'BCApi.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a6c31e2b-4d8f-4c7a-9e15-0f8b2a7d6c41'
    Author            = 'ApexDemo'
    CompanyName       = 'ApexDemo'
    Copyright         = 'Copyright (c) ApexDemo'
    Description       = 'Business Central REST/OData helpers: GET, POST, PATCH, DELETE, pagination, errors, and logging.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-BCApiBaseUrl',
        'Get-BCApiUri',
        'Get-BCCompanyId',
        'Get-BCApiErrorMessage',
        'Get-BCApiLog',
        'Clear-BCApiLog',
        'Set-BCApiHttpHandler',
        'Invoke-BCApiRequest',
        'Invoke-BCApiGet',
        'Invoke-BCApiPost',
        'Invoke-BCApiPatch',
        'Invoke-BCApiDelete'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
