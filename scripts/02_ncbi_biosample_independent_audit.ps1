[CmdletBinding()]
param(
    [string]$Project = "E:\campy-vaccine-genomics",
    [string]$RunID = "20261106T091949"
)

$ErrorActionPreference = "Stop"

$CandidateFile = Join-Path $Project "data\metadata\source_manifests\NCBI_BioSample_Candidates_v2_$RunID.csv"
$ManifestFile = Join-Path $Project "data\metadata\source_manifests\NCBI_BioSample_Search_Manifest_v2_$RunID.csv"
$ChecksumFile = Join-Path $Project "data\metadata\source_manifests\NCBI_BioSample_SHA256_v2_$RunID.csv"
$RawDirectory = Join-Path $Project "data\raw\ncbi_biosample\$RunID"

$script:Passes = 0
$script:Failures = 0

function Write-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    if ($Passed) {
        $script:Passes++
        Write-Host "[PASS] $Name - $Detail" -ForegroundColor Green
    }
    else {
        $script:Failures++
        Write-Host "[FAIL] $Name - $Detail" -ForegroundColor Red
    }
}

function Resolve-ProjectFile {
    param([string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        return $null
    }

    $Reference = $Reference.Trim().Trim('"')

    if ([System.IO.Path]::IsPathRooted($Reference)) {
        if (Test-Path -LiteralPath $Reference -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Reference).Path
        }
        return $null
    }

    $DirectPath = Join-Path $Project $Reference

    if (Test-Path -LiteralPath $DirectPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $DirectPath).Path
    }

    $FileName = [System.IO.Path]::GetFileName($Reference)

    $Matches = @(
        Get-ChildItem -LiteralPath $Project -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue
    )

    if ($Matches.Count -eq 1) {
        return $Matches[0].FullName
    }

    return $null
}

Write-Host "`n============================================"
Write-Host "NCBI BIOSAMPLE INDEPENDENT AUDIT"
Write-Host "Run ID: $RunID"
Write-Host "============================================"

# 1. Required files

Write-Host "`nSECTION 1 - REQUIRED INPUTS"

foreach ($File in @($CandidateFile, $ManifestFile, $ChecksumFile)) {
    Write-Check `
        -Name "Required file: $(Split-Path $File -Leaf)" `
        -Passed (Test-Path -LiteralPath $File -PathType Leaf) `
        -Detail $File
}

Write-Check `
    -Name "Raw response directory" `
    -Passed (Test-Path -LiteralPath $RawDirectory -PathType Container) `
    -Detail $RawDirectory

if ($script:Failures -gt 0) {
    throw "Required inputs are missing. Audit stopped."
}

# 2. Candidate CSV

Write-Host "`nSECTION 2 - CANDIDATE CSV"

$Candidates = @(Import-Csv -LiteralPath $CandidateFile)

if ($Candidates.Count -eq 0) {
    throw "Candidate CSV contains no data rows."
}

$RequiredColumns = @(
    "BioSampleAccession",
    "TaxonomyID",
    "Organism",
    "CountryVerified",
    "Collection_Date_Eligibility",
    "Raw_XML_File",
    "CountryConflict",
    "TaxonomyVerified",
    "GeoLocName_Country"
)

$AvailableColumns = @($Candidates[0].PSObject.Properties.Name)

foreach ($Column in $RequiredColumns) {
    Write-Check `
        -Name "Candidate column: $Column" `
        -Passed ($AvailableColumns -contains $Column) `
        -Detail "Column presence"
}

$Accessions = @(
    $Candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.BioSampleAccession) } |
        ForEach-Object { $_.BioSampleAccession.Trim() }
)

$UniqueAccessions = @($Accessions | Sort-Object -Unique)

$DuplicateGroups = @(
    $Accessions | Group-Object | Where-Object { $_.Count -gt 1 }
)

Write-Check "Candidate row count" ($Candidates.Count -eq 730) "Observed $($Candidates.Count); expected 730"
Write-Check "Unique BioSample accessions" ($UniqueAccessions.Count -eq 730) "Observed $($UniqueAccessions.Count); expected 730"
Write-Check "No missing accessions" ($Accessions.Count -eq $Candidates.Count) "Rows $($Candidates.Count); non-empty accessions $($Accessions.Count)"
Write-Check "No duplicate accession groups" ($DuplicateGroups.Count -eq 0) "Observed $($DuplicateGroups.Count)"

$CountryVerifiedCount = @($Candidates | Where-Object { $_.CountryVerified -match '^(True|1)$' }).Count
$TaxonomyVerifiedCount = @($Candidates | Where-Object { $_.TaxonomyVerified -match '^(True|1)$' }).Count
$ConflictCount = @($Candidates | Where-Object { $_.CountryConflict -match '^(True|1)$' }).Count

Write-Check "Country verification" ($CountryVerifiedCount -eq 730) "Verified $CountryVerifiedCount of 730"
Write-Check "Taxonomy verification" ($TaxonomyVerifiedCount -eq 730) "Verified $TaxonomyVerifiedCount of 730"
Write-Check "Country conflicts" ($ConflictCount -eq 0) "Observed $ConflictCount; expected 0"

Write-Host "`nCountry distribution:"
$Candidates |
    Group-Object GeoLocName_Country |
    Sort-Object Name |
    ForEach-Object {
        Write-Host ("{0}: {1}" -f $_.Name, $_.Count)
    }

# 3. Date classifications

Write-Host "`nSECTION 3 - COLLECTION DATE CLASSIFICATION"

$DateGroups = @(
    $Candidates | Group-Object Collection_Date_Eligibility
)

foreach ($Group in $DateGroups) {
    Write-Host ("{0}: {1}" -f $Group.Name, $Group.Count)
}

$WithinExact = @($Candidates | Where-Object {
    $_.Collection_Date_Eligibility -eq "Within study period"
}).Count

$WithinYearPrecision = @($Candidates | Where-Object {
    $_.Collection_Date_Eligibility -eq "Within study period - year precision"
}).Count

$OutsidePeriod = @($Candidates | Where-Object {
    $_.Collection_Date_Eligibility -eq "Outside study period"
}).Count

$MissingDate = @($Candidates | Where-Object {
    $_.Collection_Date_Eligibility -eq "Unresolved - date missing"
}).Count

Write-Check "Specific dates within study period" ($WithinExact -eq 523) "Observed $WithinExact; expected 523"
Write-Check "Year-only dates within study-year bracket" ($WithinYearPrecision -eq 81) "Observed $WithinYearPrecision; expected 81"
Write-Check "Outside study period" ($OutsidePeriod -eq 98) "Observed $OutsidePeriod; expected 98"
Write-Check "Missing or unresolved dates" ($MissingDate -eq 28) "Observed $MissingDate; expected 28"

# 4. XML parsing and accession reconciliation

Write-Host "`nSECTION 4 - XML RESPONSE AUDIT"

$XmlFiles = @(Get-ChildItem -LiteralPath $RawDirectory -Filter "*.xml" -File)

$XmlTotal = 0
$XmlParseFailures = 0

$XmlAccessionSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($XmlFile in $XmlFiles) {
    try {
        [xml]$XmlDocument = Get-Content -LiteralPath $XmlFile.FullName -Raw

        $Nodes = @($XmlDocument.SelectNodes("//*[local-name()='BioSample']"))
        $XmlTotal += $Nodes.Count

        foreach ($Node in $Nodes) {
            $Accession = $Node.GetAttribute("accession")
            if (-not [string]::IsNullOrWhiteSpace($Accession)) {
                [void]$XmlAccessionSet.Add($Accession.Trim())
            }
        }

        Write-Host "[XML OK] $($XmlFile.Name): $($Nodes.Count) BioSample nodes" -ForegroundColor Green
    }
    catch {
        $XmlParseFailures++
        Write-Host "[XML ERROR] $($XmlFile.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Check "Number of XML files" ($XmlFiles.Count -eq 6) "Observed $($XmlFiles.Count); expected 6"
Write-Check "XML parsing" ($XmlParseFailures -eq 0) "Parse failures $XmlParseFailures"
Write-Check "Total XML BioSample nodes" ($XmlTotal -eq 730) "Observed $XmlTotal; expected 730"
Write-Check "Unique XML accessions" ($XmlAccessionSet.Count -eq 730) "Observed $($XmlAccessionSet.Count); expected 730"

$MissingFromXML = @(
    $UniqueAccessions | Where-Object { -not $XmlAccessionSet.Contains($_) }
)

$MissingFromCSV = @(
    $XmlAccessionSet | Where-Object { $_ -notin $UniqueAccessions }
)

Write-Check "Candidate accessions present in XML" ($MissingFromXML.Count -eq 0) "Missing $($MissingFromXML.Count)"
Write-Check "XML accessions present in candidate CSV" ($MissingFromCSV.Count -eq 0) "Missing $($MissingFromCSV.Count)"

# 5. Candidate-to-XML references

Write-Host "`nSECTION 5 - CANDIDATE TO XML REFERENCES"

$XmlReferences = @(
    $Candidates |
        Select-Object -ExpandProperty Raw_XML_File -Unique
)

$MissingXmlReferences = 0

foreach ($Reference in $XmlReferences) {
    if (-not (Resolve-ProjectFile -Reference $Reference)) {
        $MissingXmlReferences++
        Write-Host "[MISSING XML REFERENCE] $Reference" -ForegroundColor Red
    }
}

Write-Check "Candidate XML references" `
    ($MissingXmlReferences -eq 0 -and $XmlReferences.Count -eq 6) `
    "Unique references $($XmlReferences.Count); missing $MissingXmlReferences"

# 6. Search manifest

Write-Host "`nSECTION 6 - SEARCH MANIFEST"

$Manifest = @(Import-Csv -LiteralPath $ManifestFile)

$ManifestTotal = 0
$InvalidManifestCounts = 0
$MissingSearchFiles = 0

foreach ($Entry in $Manifest) {
    $Count = 0

    if ([int]::TryParse([string]$Entry.ResultCount, [ref]$Count)) {
        $ManifestTotal += $Count
    }
    else {
        $InvalidManifestCounts++
    }

    if (-not (Resolve-ProjectFile -Reference $Entry.RawSearchFile)) {
        $MissingSearchFiles++
    }
}

Write-Check "Search manifest rows" ($Manifest.Count -eq 5) "Observed $($Manifest.Count); expected 5"
Write-Check "Search manifest result total" ($ManifestTotal -eq 730) "Observed $ManifestTotal; expected 730"
Write-Check "Valid manifest counts" ($InvalidManifestCounts -eq 0) "Invalid counts $InvalidManifestCounts"
Write-Check "Manifest raw response references" ($MissingSearchFiles -eq 0) "Missing references $MissingSearchFiles"

Write-Host "`nSearch alias counts:"
$Manifest | ForEach-Object {
    Write-Host ("{0}: {1}" -f $_.SearchAlias, $_.ResultCount)
}

# 7. Response sidecars

Write-Host "`nSECTION 7 - REQUEST SIDECARS"

$ResponseFiles = @(
    Get-ChildItem -LiteralPath $RawDirectory -File |
        Where-Object { $_.Extension -in @(".xml", ".json") }
)

$MissingSidecars = @(
    $ResponseFiles | Where-Object {
        -not (Test-Path -LiteralPath ($_.FullName + ".request.txt") -PathType Leaf)
    }
)

Write-Check "JSON/XML response file count" ($ResponseFiles.Count -eq 17) "Observed $($ResponseFiles.Count); expected 17"
Write-Check "Request sidecars" ($MissingSidecars.Count -eq 0) "Missing $($MissingSidecars.Count)"

# 8. Checksums

Write-Host "`nSECTION 8 - SHA256 CHECKSUM VERIFICATION"

$ChecksumEntries = @(Import-Csv -LiteralPath $ChecksumFile)

$ChecksumMissing = 0
$ChecksumMismatch = 0
$ChecksumVerified = 0

foreach ($Entry in $ChecksumEntries) {
    $Reference = $Entry.File

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        $Reference = $Entry.FileName
    }

    $Resolved = Resolve-ProjectFile -Reference $Reference

    if (-not $Resolved) {
        $ChecksumMissing++
        Write-Host "[MISSING CHECKSUM FILE] $Reference" -ForegroundColor Red
        continue
    }

    $ActualHash = (Get-FileHash -LiteralPath $Resolved -Algorithm SHA256).Hash

    if ($ActualHash -ieq $Entry.SHA256) {
        $ChecksumVerified++
    }
    else {
        $ChecksumMismatch++
        Write-Host "[HASH MISMATCH] $Reference" -ForegroundColor Red
    }
}

Write-Check "Checksum manifest entries" ($ChecksumEntries.Count -eq 39) "Observed $($ChecksumEntries.Count); expected 39"
Write-Check "Checksum files exist" ($ChecksumMissing -eq 0) "Missing $ChecksumMissing"
Write-Check "SHA256 integrity" ($ChecksumMismatch -eq 0 -and $ChecksumVerified -eq 39) "Verified $ChecksumVerified; mismatches $ChecksumMismatch"

# 9. Final result

Write-Host "`n============================================"
Write-Host "FINAL AUDIT SUMMARY"
Write-Host "============================================"
Write-Host "Run ID: $RunID"
Write-Host "Candidate records: $($Candidates.Count)"
Write-Host "Unique BioSample accessions: $($UniqueAccessions.Count)"
Write-Host "XML files: $($XmlFiles.Count)"
Write-Host "XML BioSample nodes: $XmlTotal"
Write-Host "Search manifest rows: $($Manifest.Count)"
Write-Host "Response files: $($ResponseFiles.Count)"
Write-Host "Checksum entries: $($ChecksumEntries.Count)"
Write-Host "Checks passed: $script:Passes"
Write-Host "Checks failed: $script:Failures"

if ($script:Failures -eq 0) {
    Write-Host "`nAUDIT PASSED" -ForegroundColor Green
    Write-Host "Archived discovery outputs passed the configured checks."
    Write-Host "This does not establish final independent-isolate or genome eligibility."
}
else {
    Write-Host "`nAUDIT FAILED" -ForegroundColor Red
    Write-Host "Review failed checks before accepting the audit."
    exit 1
}

Write-Host "`nAudit completed. No discovery files were modified."
