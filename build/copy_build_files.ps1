param (
    $Destination = '.',
    $Type = 'Release'
)
foreach ($f in (Get-Item .\src\dbops-* -Exclude dbops-tests)) {
    'net45', 'netstandard2.0' | ForEach-Object {
        Write-Host "Updating $_ library: $($f.Name)"
        Copy-Item "$($f.FullName)\bin\$Type\$_\$($f.Name).dll" "$Destination\bin\lib\$_\$($f.Name).dll"
    }
}