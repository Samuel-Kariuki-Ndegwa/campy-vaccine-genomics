[CmdletBinding()]
param(
    [switch]$TestOnly,
    [switch]$LiveSearch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# 1. Resolve project paths and execution timestamp
# ------------------------------------------------------------

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $ProjectRoot "config\project_config.yaml"

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw "Configuration file not found: $ConfigFile"
}

$RunTime = Get-Date
$RunID = $RunTime.ToString("yyyyMMddTHHmmss")
$SearchCutoff = $RunTime.Date

# ------------------------------------------------------------
# 2. Read and validate the project's YAML configuration
#    This is a constrained reader for the known project schema.
#    It does not require an external YAML module.
# ------------------------------------------------------------

$ConfigText = Get-Content -LiteralPath $ConfigFile -Raw

function Get-ConfigScalar {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Description
    )

    $Matches = [regex]::Matches($Text, $Pattern)

    if ($Matches.Count -ne 1) {
        throw "Expected exactly one configuration value for $Description; found $($Matches.Count)."
    }

    return $Matches[0].Groups[1].Value.Trim()
}

$ScientificName = Get-ConfigScalar `
    -Text $ConfigText `
    -Pattern '(?m)^\s{2}scientific_name:\s*"([^"]+)"\s*$' `
    -Description "organism scientific name"

$TaxonomyIDText = Get-ConfigScalar `
    -Text $ConfigText `
    -Pattern '(?m)^\s{2}ncbi_taxonomy_id:\s*(\d+)\s*$' `
    -Description "NCBI taxonomy ID"

$StartDateText = Get-ConfigScalar `
    -Text $ConfigText `
    -Pattern '(?m)^\s{2}start_date:\s*"(\d{4}-\d{2}-\d{2})"\s*$' `
    -Description "collection-period start date"

$TaxonomyID = [int]$TaxonomyIDText
$StudyStartDate = [datetime]::ParseExact(
    $StartDateText,
    "yyyy-MM-dd",
    [Globalization.CultureInfo]::InvariantCulture
)

if ($ScientificName -ne "Campylobacter jejuni") {
    throw "Unexpected organism in configuration: $ScientificName"
}

if ($TaxonomyID -ne 197) {
    throw "Unexpected taxonomy ID: $TaxonomyID"
}

if ($StudyStartDate.ToString("yyyy-MM-dd") -ne "2017-01-01") {
    throw "Study start date must remain 2017-01-01. Found: $StartDateText"
}

# The agreed study period ends in 2026.
# The actual execution date is the search cut-off.
$StudyEndYear = 2026
$CalendarEndDate = [datetime]::new($StudyEndYear, 12, 31)

# The operational end date is the earlier of:
# 1. The actual database search cut-off.
# 2. The end of the agreed 2026 study year.
if ($SearchCutoff -lt $CalendarEndDate) {
    $StudyEndDate = $SearchCutoff
}
else {
    $StudyEndDate = $CalendarEndDate
}

if ($StudyStartDate -gt $StudyEndDate) {
    throw "Invalid study period: start date is after the study end date."
}

# ------------------------------------------------------------
# 3. Read country definitions and aliases from YAML
# ------------------------------------------------------------

$ConfigLines = $ConfigText -split "\r?\n"

$CountryStartIndexes = @()

for ($i = 0; $i -lt $ConfigLines.Count; $i++) {
    if ($ConfigLines[$i] -match '^\s{4}- name:\s*"[^"]+"\s*$') {
        $CountryStartIndexes += $i
    }
}

if ($CountryStartIndexes.Count -ne 4) {
    throw "Expected four country entries in configuration; found $($CountryStartIndexes.Count)."
}

$Countries = @()

for ($CountryIndex = 0; $CountryIndex -lt $CountryStartIndexes.Count; $CountryIndex++) {
    $BlockStart = $CountryStartIndexes[$CountryIndex]

    if ($CountryIndex -lt ($CountryStartIndexes.Count - 1)) {
        $BlockEnd = $CountryStartIndexes[$CountryIndex + 1] - 1
    }
    else {
        $BlockEnd = $ConfigLines.Count - 1
    }

    $BlockLines = @($ConfigLines[$BlockStart..$BlockEnd])

    $NameMatch = [regex]::Match(
        $BlockLines[0],
        '^\s{4}- name:\s*"([^"]+)"\s*$'
    )

    $ISO3Match = [regex]::Match(
        ($BlockLines -join "`n"),
        '(?m)^\s{6}iso3:\s*"([^"]+)"\s*$'
    )

    if (-not $NameMatch.Success -or -not $ISO3Match.Success) {
        throw "Could not parse country name or ISO3 code in configuration block $($CountryIndex + 1)."
    }

    $AliasValues = @()

    foreach ($BlockLine in $BlockLines) {
        $AliasMatch = [regex]::Match(
            $BlockLine,
            '^\s{8}-\s*"([^"]+)"\s*$'
        )

        if ($AliasMatch.Success) {
            $AliasValues += $AliasMatch.Groups[1].Value.Trim()
        }
    }

    if ($AliasValues.Count -eq 0) {
        throw "No search aliases found for $($NameMatch.Groups[1].Value)."
    }

    $Countries += [pscustomobject]@{
        Name = $NameMatch.Groups[1].Value.Trim()
        ISO3 = $ISO3Match.Groups[1].Value.Trim()
        Aliases = @($AliasValues)
    }
}

$ExpectedCountries = @("Kenya", "Ethiopia", "Tanzania", "Uganda")

foreach ($Expected in $ExpectedCountries) {
    if ($Countries.Name -notcontains $Expected) {
        throw "Required country missing from configuration: $Expected"
    }
}
# 4. Collection-date classification
#    Only specimen collection dates are considered.
# ------------------------------------------------------------

$MissingDatePlaceholders = @(
    "",
    "missing",
    "not provided",
    "not available",
    "unknown",
    "n/a",
    "na",
    "none",
    "null",
    "not collected",
    "not applicable"
)

function Get-CollectionDateClassification {
    param(
        [AllowNull()]
        [string]$OriginalDate
    )

    $Original = ""
    if ($null -ne $OriginalDate) {
        $Original = $OriginalDate.Trim()
    }

    $Result = [ordered]@{
        Collection_Date_Original = $Original
        Collection_Date_Precision = "Unresolved"
        Collection_Date_Status = "Unresolved"
        Collection_Date_Eligibility = "Requires review"
        Collection_Date_Start = ""
        Collection_Date_End = ""
    }

    if ($MissingDatePlaceholders -contains $Original.ToLowerInvariant()) {
        $Result.Collection_Date_Precision = "Missing or placeholder"
        $Result.Collection_Date_Status = "Missing"
        $Result.Collection_Date_Eligibility = "Unresolved - date missing"
        return [pscustomobject]$Result
    }

    $DateStart = [datetime]::MinValue
    $DateEnd = [datetime]::MinValue

    # Exact ISO date: YYYY-MM-DD
    if ($Original -match '^\d{4}-\d{2}-\d{2}$') {
        $Parsed = [datetime]::MinValue
        $Valid = [datetime]::TryParseExact(
            $Original,
            "yyyy-MM-dd",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$Parsed
        )

        if (-not $Valid) {
            $Result.Collection_Date_Precision = "Exact date"
            $Result.Collection_Date_Status = "Invalid date"
            $Result.Collection_Date_Eligibility = "Unresolved - invalid date"
            return [pscustomobject]$Result
        }

        $DateStart = $Parsed.Date
        $DateEnd = $Parsed.Date
        $Result.Collection_Date_Precision = "Exact date"
    }
    # Month precision: YYYY-MM
    elseif ($Original -match '^\d{4}-\d{2}$') {
        $Parsed = [datetime]::MinValue
        $Valid = [datetime]::TryParseExact(
            "$Original-01",
            "yyyy-MM-dd",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$Parsed
        )

        if (-not $Valid) {
            $Result.Collection_Date_Precision = "Month-level"
            $Result.Collection_Date_Status = "Invalid date"
            $Result.Collection_Date_Eligibility = "Unresolved - invalid date"
            return [pscustomobject]$Result
        }

        $DateStart = $Parsed.Date
        $DateEnd = $Parsed.AddMonths(1).AddDays(-1).Date
        $Result.Collection_Date_Precision = "Month-level"
    }
    # Year precision: YYYY
    elseif ($Original -match '^\d{4}$') {
        $Year = [int]$Original

        if ($Year -lt 1 -or $Year -gt 9999) {
            $Result.Collection_Date_Precision = "Year-only"
            $Result.Collection_Date_Status = "Invalid date"
            $Result.Collection_Date_Eligibility = "Unresolved - invalid year"
            return [pscustomobject]$Result
        }

        $DateStart = [datetime]::new($Year, 1, 1)
        $DateEnd = [datetime]::new($Year, 12, 31)
        $Result.Collection_Date_Precision = "Year-only"
    }
    # Explicit date range: YYYY-MM-DD/YYYY-MM-DD
    elseif ($Original -match '^(\d{4}-\d{2}-\d{2})\s*/\s*(\d{4}-\d{2}-\d{2})$') {
        $StartText = $Matches[1]
        $EndText = $Matches[2]

        $StartParsed = [datetime]::MinValue
        $EndParsed = [datetime]::MinValue

        $StartValid = [datetime]::TryParseExact(
            $StartText, "yyyy-MM-dd",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$StartParsed
        )

        $EndValid = [datetime]::TryParseExact(
            $EndText, "yyyy-MM-dd",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$EndParsed
        )

        if (-not $StartValid -or -not $EndValid -or $EndParsed -lt $StartParsed) {
            $Result.Collection_Date_Precision = "Date range"
            $Result.Collection_Date_Status = "Invalid or ambiguous range"
            $Result.Collection_Date_Eligibility = "Unresolved - invalid range"
            return [pscustomobject]$Result
        }

        $DateStart = $StartParsed.Date
        $DateEnd = $EndParsed.Date
        $Result.Collection_Date_Precision = "Date range"
    }
    else {
        $Result.Collection_Date_Precision = "Unrecognised format"
        $Result.Collection_Date_Status = "Ambiguous or unsupported"
        $Result.Collection_Date_Eligibility = "Unresolved - manual review"
        return [pscustomobject]$Result
    }

    $Result.Collection_Date_Start = $DateStart.ToString("yyyy-MM-dd")
    $Result.Collection_Date_End = $DateEnd.ToString("yyyy-MM-dd")

    # Year-only dates are evaluated against the agreed year bracket.
    # More precise dates are evaluated against the actual search cut-off.
    if ($Result.Collection_Date_Precision -eq "Year-only") {
        if ($DateStart.Year -ge 2017 -and $DateStart.Year -le 2026) {
            $Result.Collection_Date_Status = "Within study years"
            $Result.Collection_Date_Eligibility = "Within study period - year precision"
        }
        else {
            $Result.Collection_Date_Status = "Outside study years"
            $Result.Collection_Date_Eligibility = "Outside study period"
        }

        return [pscustomobject]$Result
    }

    if ($DateStart -gt $CalendarEndDate) {
        $Result.Collection_Date_Status = "Outside study period"
        $Result.Collection_Date_Eligibility = "Outside study period"
    }
    elseif ($DateStart -gt $StudyEndDate) {
        $Result.Collection_Date_Status = "After search cut-off"
        $Result.Collection_Date_Eligibility = "Unresolved - after search cut-off"
    }
    elseif ($DateEnd -lt $StudyStartDate) {
        $Result.Collection_Date_Status = "Outside study period"
        $Result.Collection_Date_Eligibility = "Outside study period"
    }
    elseif (
        $DateStart -ge $StudyStartDate -and
        $DateEnd -le $StudyEndDate
    ) {
        $Result.Collection_Date_Status = "Within study period"
        $Result.Collection_Date_Eligibility = "Within study period"
    }
    else {
        $Result.Collection_Date_Status = "Overlaps study period"
        $Result.Collection_Date_Eligibility = "Partial overlap - review"
    }

    return [pscustomobject]$Result
}

# ------------------------------------------------------------
# 5. Test-only validation
# ------------------------------------------------------------

if ($TestOnly) {
    $Tests = @(
        @{ Date = "2017-01-01"; Expected = "Within study period" },
        @{ Date = "2022"; Expected = "Within study years" },
        @{ Date = "2026"; Expected = "Within study years" },
        @{ Date = "2016"; Expected = "Outside study years" },
        @{ Date = "2022-05"; Expected = "Within study period" },
        @{ Date = "missing"; Expected = "Missing" },
        @{ Date = "not provided"; Expected = "Missing" },
        @{ Date = "2022-02-30"; Expected = "Invalid date" },
        @{ Date = "2016-01-01/2018-01-01"; Expected = "Overlaps study period" },
        @{ Date = "2020-01-01/2020-12-31"; Expected = "Within study period" },
        @{ Date = "2027-01-01"; Expected = "Outside study period" }
    )

    if ($SearchCutoff -lt $CalendarEndDate) {
        $AfterCutoffTestDate = $SearchCutoff.AddDays(1).ToString("yyyy-MM-dd")
        $CutoffRangeTestDate = (
            $SearchCutoff.ToString("yyyy-MM-dd") + "/" +
            $SearchCutoff.AddDays(1).ToString("yyyy-MM-dd")
        )

        $Tests += @{
            Date = $AfterCutoffTestDate
            Expected = "After search cut-off"
        }

        $Tests += @{
            Date = $CutoffRangeTestDate
            Expected = "Overlaps study period"
        }
    }

    $Failures = @()

    foreach ($Test in $Tests) {
        $Actual = Get-CollectionDateClassification -OriginalDate $Test.Date

        if ($Actual.Collection_Date_Status -ne $Test.Expected) {
            $Failures += [pscustomobject]@{
                Input = $Test.Date
                Expected = $Test.Expected
                Actual = $Actual.Collection_Date_Status
            }
        }
    }

    Write-Host ""
    Write-Host "CONFIGURATION VALIDATION" -ForegroundColor Cyan
    Write-Host "Organism: $ScientificName"
    Write-Host "Taxonomy ID: $TaxonomyID"
    Write-Host "Study start: $($StudyStartDate.ToString('yyyy-MM-dd'))"
    Write-Host "Study end year: $StudyEndYear"
    Write-Host "Execution cut-off: $($SearchCutoff.ToString('yyyy-MM-dd'))"
    Write-Host "Countries: $($Countries.Name -join ', ')"

    Write-Host ""
    Write-Host "DATE CLASSIFICATION TESTS" -ForegroundColor Cyan

    if ($Failures.Count -gt 0) {
        $Failures | Format-Table -AutoSize
        throw "Test-only validation failed: $($Failures.Count) date test(s) failed."
    }

    Write-Host "Passed: $($Tests.Count) of $($Tests.Count)" -ForegroundColor Green
    Write-Host "TEST-ONLY VALIDATION PASSED" -ForegroundColor Green
    Write-Host "No NCBI requests were made."
    return
}

# ------------------------------------------------------------
# 6. Require explicit live-search switch
# ------------------------------------------------------------

if (-not $LiveSearch) {
    throw "No action taken. Run with -TestOnly or explicitly use -LiveSearch."
}

# Central request throttle: minimum 400 ms between NCBI requests.
$script:LastNcbiRequestTime = [datetime]::MinValue

function Invoke-NcbiRequest {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Uri,

        [Parameter(Mandatory=$true)]
        [ValidateSet("Json","Xml")]
        [string]$ResponseType
    )

    if ($script:LastNcbiRequestTime -ne [datetime]::MinValue) {
        $Elapsed = ([datetime]::UtcNow - $script:LastNcbiRequestTime).TotalMilliseconds
        $Remaining = 400 - $Elapsed

        if ($Remaining -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Ceiling($Remaining))
        }
    }

    $script:LastNcbiRequestTime = [datetime]::UtcNow

    if ($ResponseType -eq "Json") {
        return Invoke-RestMethod -Uri $Uri -Method Get
    }

    return Invoke-WebRequest -Uri $Uri -Method Get -UseBasicParsing
}

# ------------------------------------------------------------
# 7. Prepare timestamped output directories
# ------------------------------------------------------------

$RawDirectory = Join-Path $ProjectRoot "data\raw\ncbi_biosample\$RunID"
$ManifestDirectory = Join-Path $ProjectRoot "data\metadata\source_manifests"
$ReportDirectory = Join-Path $ProjectRoot "results\database_searches"
$LogDirectory = Join-Path $ProjectRoot "logs"

# The run-specific raw directory must be new.
if (Test-Path -LiteralPath $RawDirectory) {
    throw "Run-specific raw directory already exists; refusing to overwrite: $RawDirectory"
}

# Shared project directories may already exist.
$SharedDirectories = @(
    $ManifestDirectory,
    $ReportDirectory,
    $LogDirectory
)

foreach ($Directory in $SharedDirectories) {
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

New-Item -ItemType Directory -Path $RawDirectory -Force | Out-Null

$TranscriptFile = Join-Path $LogDirectory "NCBI_BioSample_Discovery_v2_$RunID.log"

if (Test-Path -LiteralPath $TranscriptFile) {
    throw "Transcript already exists; refusing to overwrite: $TranscriptFile"
}

Start-Transcript -LiteralPath $TranscriptFile | Out-Null

try {
    Write-Host "NCBI BioSample fresh discovery started: $RunID"
    Write-Host "Organism: $ScientificName (Taxonomy ID $TaxonomyID)"
    Write-Host "Study period: 2017–2026"
    Write-Host "Search cut-off: $($SearchCutoff.ToString('yyyy-MM-dd'))"

    $AllRecords = @()
    $SearchManifest = @()
    $BatchSize = 200
    $MaximumRecordsPerAlias = 10000

    # --------------------------------------------------------
    # 8. Search each configured country alias independently
    # --------------------------------------------------------

    foreach ($Country in $Countries) {
        foreach ($Alias in $Country.Aliases) {
            $Term = "txid$TaxonomyID[Organism:exp] AND `"$Alias`"[All Fields]"
            $EncodedTerm = [uri]::EscapeDataString($Term)

            $SearchURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=biosample&term=$EncodedTerm&retmode=json&retmax=0"

            Write-Host ""
            Write-Host "Searching $($Country.Name): $Alias"

            $SearchResponse = Invoke-NcbiRequest -Uri $SearchURL -ResponseType Json
            $Count = [int]$SearchResponse.esearchresult.count

            $SearchRawFile = Join-Path $RawDirectory (
                "ESearch_{0}_{1}.json" -f $Country.ISO3, ([guid]::NewGuid().ToString("N"))
            )

            $SearchResponse |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $SearchRawFile -Encoding UTF8

            Set-Content -LiteralPath ($SearchRawFile + ".request.txt") `
                -Value $SearchURL -Encoding UTF8

            $SearchManifest += [pscustomobject]@{
                Country = $Country.Name
                ISO3 = $Country.ISO3
                SearchAlias = $Alias
                SearchTerm = $Term
                Database = "BioSample"
                ResultCount = $Count
                SearchCutoff = $SearchCutoff.ToString("yyyy-MM-dd")
                RawSearchFile = $SearchRawFile
            }

            if ($Count -gt $MaximumRecordsPerAlias) {
                throw "Search returned $Count records for $Alias, exceeding the safety limit of $MaximumRecordsPerAlias. No partial retrieval will be treated as complete."
            }

            if ($Count -eq 0) {
                continue
            }

            $IDs = @()
            $RetMax = [Math]::Min($BatchSize, $Count)

            $IDURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=biosample&term=$EncodedTerm&retmode=json&retstart=0&retmax=$RetMax"

            $IDResponse = Invoke-NcbiRequest -Uri $IDURL -ResponseType Json

            $IDRawFile = Join-Path $RawDirectory (
                "ESearch_ID_{0}_{1}.json" -f $Country.ISO3, ([guid]::NewGuid().ToString("N"))
            )

            $IDResponse |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $IDRawFile -Encoding UTF8

            Set-Content -LiteralPath ($IDRawFile + ".request.txt") `
                -Value $IDURL -Encoding UTF8

            $IDs += @($IDResponse.esearchresult.idlist)

            $FetchedCount = $IDs.Count

            while ($FetchedCount -lt $Count) {
                Start-Sleep -Milliseconds 400

                $NextRetMax = [Math]::Min($BatchSize, ($Count - $FetchedCount))
                $NextURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=biosample&term=$EncodedTerm&retmode=json&retstart=$FetchedCount&retmax=$NextRetMax"

                $NextResponse = Invoke-NcbiRequest -Uri $NextURL -ResponseType Json

                $NextRawFile = Join-Path $RawDirectory (
                    "ESearch_Next_{0}_{1}.json" -f $Country.ISO3, ([guid]::NewGuid().ToString("N"))
                )

                $NextResponse |
                    ConvertTo-Json -Depth 20 |
                    Set-Content -LiteralPath $NextRawFile -Encoding UTF8

                Set-Content -LiteralPath ($NextRawFile + ".request.txt") `
                    -Value $NextURL -Encoding UTF8

                $NextIDs = @($NextResponse.esearchresult.idlist)

                if ($NextIDs.Count -eq 0) {
                    break
                }

                $IDs += $NextIDs
                $FetchedCount += $NextIDs.Count
            }

            if ($IDs.Count -ne $Count) {
                throw "Incomplete ID retrieval for $Alias. Expected $Count; retrieved $($IDs.Count)."
            }

            # ------------------------------------------------
            # 9. Fetch BioSample XML in batches
            # ------------------------------------------------

            for ($Offset = 0; $Offset -lt $IDs.Count; $Offset += $BatchSize) {
                $EndIndex = [Math]::Min($Offset + $BatchSize - 1, $IDs.Count - 1)
                $BatchIDs = @($IDs[$Offset..$EndIndex])
                $IDString = $BatchIDs -join ","

                Start-Sleep -Milliseconds 400

                $FetchURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=biosample&id=$IDString&retmode=xml"
                $XMLResponse = Invoke-NcbiRequest -Uri $FetchURL -ResponseType Xml

                $AliasSlug = ($Alias -replace '[^A-Za-z0-9]+', '_').Trim('_')

                $XMLFile = Join-Path $RawDirectory (
                    "EFetch_{0}_{1}_{2:D5}.xml" -f $Country.ISO3, $AliasSlug, $Offset
                )

                Set-Content -LiteralPath $XMLFile -Value $XMLResponse.Content -Encoding UTF8

                Set-Content -LiteralPath ($XMLFile + ".request.txt") `
                    -Value $FetchURL -Encoding UTF8

                [xml]$XML = $XMLResponse.Content
                $BioSampleNodes = $XML.SelectNodes("//*[local-name()='BioSample']")

                if ($BioSampleNodes.Count -ne $BatchIDs.Count) {
                    throw "EFetch batch incomplete for $($Country.Name). Requested $($BatchIDs.Count); received $($BioSampleNodes.Count). Raw XML preserved at $XMLFile"
                }

                foreach ($Node in $BioSampleNodes) {
                    $Accession = [string]$Node.GetAttribute("accession")
                    $OrganismNode = $Node.SelectSingleNode("./*[local-name()='Description']/*[local-name()='Organism']")

                    $RecordTaxonomy = ""
                    $RecordOrganism = ""

                    if ($null -ne $OrganismNode) {
                        $RecordTaxonomy = [string]$OrganismNode.GetAttribute("taxonomy_id")
                        $RecordOrganism = [string]$OrganismNode.GetAttribute("taxonomy_name")
                    }

                    $AttributeMap = @{}

                    $AttributeNodes = $Node.SelectNodes(".//*[local-name()='Attributes']/*[local-name()='Attribute']")

                    foreach ($AttributeNode in $AttributeNodes) {
                        $AttributeName = [string]$AttributeNode.GetAttribute("attribute_name")

                        if ([string]::IsNullOrWhiteSpace($AttributeName)) {
                            $AttributeName = [string]$AttributeNode.GetAttribute("harmonized_name")
                        }

                        $AttributeValue = [string]$AttributeNode.InnerText

                        if (-not [string]::IsNullOrWhiteSpace($AttributeName)) {
                            $AttributeMap[$AttributeName.Trim().ToLowerInvariant()] = $AttributeValue.Trim()
                        }
                    }

                    $CollectionDate = ""
                    foreach ($DateKey in @("collection_date", "collection date")) {
                        if ($AttributeMap.ContainsKey($DateKey)) {
                            $CollectionDate = $AttributeMap[$DateKey]
                            break
                        }
                    }

                    $GeoValue = ""
                    foreach ($GeoKey in @(
                        "geo_loc_name",
                        "geographic location",
                        "geographic location (country and/or sea)"
                    )) {
                        if ($AttributeMap.ContainsKey($GeoKey)) {
                            $GeoValue = $AttributeMap[$GeoKey]
                            break
                        }
                    }

                    $GeoCountry = ""
                    if (-not [string]::IsNullOrWhiteSpace($GeoValue)) {
                        $GeoCountry = ($GeoValue -split ":", 2)[0].Trim()
                    }

                    $CountryVerified = $false
                    foreach ($AliasCandidate in $Country.Aliases) {
                        if ($GeoCountry -ieq $AliasCandidate) {
                            $CountryVerified = $true
                            break
                        }
                    }

                    $TitleNode = $Node.SelectSingleNode("./*[local-name()='Description']/*[local-name()='Title']")
                    $SampleTitle = ""
                    if ($null -ne $TitleNode) {
                        $SampleTitle = [string]$TitleNode.InnerText
                    }
                    $DateClassification = Get-CollectionDateClassification -OriginalDate $CollectionDate

                    $AllRecords += [pscustomobject]@{
                        BioSampleAccession = $Accession
                        TaxonomyID = $RecordTaxonomy
                        Organism = $RecordOrganism
                        QueriedCountry = $Country.Name
                        QueriedAlias = $Alias
                        GeoLocName_Original = $GeoValue
                        GeoLocName_Country = $GeoCountry
                        CountryVerified = $CountryVerified
                        Collection_Date_Original = $DateClassification.Collection_Date_Original
                        Collection_Date_Precision = $DateClassification.Collection_Date_Precision
                        Collection_Date_Status = $DateClassification.Collection_Date_Status
                        Collection_Date_Eligibility = $DateClassification.Collection_Date_Eligibility
                        Collection_Date_Start = $DateClassification.Collection_Date_Start
                        Collection_Date_End = $DateClassification.Collection_Date_End
                        Isolate = $AttributeMap["isolate"]
                        Strain = $AttributeMap["strain"]
                        Host = $AttributeMap["host"]
                        BioProject = $AttributeMap["bioproject"]
                        Sample_Title = $SampleTitle
                        Raw_XML_File = $XMLFile
                    }
                }
            }
        }
    }

    # --------------------------------------------------------
    # 10. Consolidate repeated BioSample accessions
    #     Do not treat repeated query hits as separate isolates.
    # --------------------------------------------------------

    $ConsolidatedRecords = @()

    $MissingAccessionRecords = @(
        $AllRecords |
            Where-Object { [string]::IsNullOrWhiteSpace($_.BioSampleAccession) }
    )

    $MissingAccessionFile = Join-Path $RawDirectory "Records_Missing_BioSample_Accessions.csv"

    if ($MissingAccessionRecords.Count -gt 0) {
        $MissingAccessionRecords |
            Export-Csv -LiteralPath $MissingAccessionFile -NoTypeInformation -Encoding UTF8
    }

    $GroupedRecords = $AllRecords |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.BioSampleAccession) } |
        Group-Object BioSampleAccession

    foreach ($Group in $GroupedRecords) {
        $VerifiedGroupRecords = @(
            $Group.Group | Where-Object { $_.CountryVerified }
        )

        if ($VerifiedGroupRecords.Count -gt 0) {
            $First = $VerifiedGroupRecords[0]
        }
        else {
            $First = $Group.Group[0]
        }

        $QueryCountries = @(
            $Group.Group |
                Select-Object -ExpandProperty QueriedCountry -Unique
        ) -join ";"

        $DistinctObservedCountries = @(
            $Group.Group |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.GeoLocName_Country)
                } |
                ForEach-Object {
                    $_.GeoLocName_Country.Trim()
                } |
                Sort-Object -Unique
        )

        $DistinctVerifiedCountries = @(
            $VerifiedGroupRecords |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.GeoLocName_Country)
                } |
                ForEach-Object {
                    $_.GeoLocName_Country.Trim()
                } |
                Sort-Object -Unique
        )

        $ObservedCountries = $DistinctObservedCountries -join ";"
        $VerifiedCountries = $DistinctVerifiedCountries -join ";"
        $CountryConflict = ($DistinctObservedCountries.Count -gt 1)

        $First.CountryVerified = ($VerifiedGroupRecords.Count -gt 0)

        $First | Add-Member -NotePropertyName QueryCountries -NotePropertyValue $QueryCountries -Force
        $First | Add-Member -NotePropertyName VerifiedCountryValues -NotePropertyValue $VerifiedCountries -Force
        $First | Add-Member -NotePropertyName ObservedCountryValues -NotePropertyValue $ObservedCountries -Force
        $First | Add-Member -NotePropertyName CountryConflict -NotePropertyValue $CountryConflict -Force
        $First | Add-Member -NotePropertyName QueryHitCount -NotePropertyValue $Group.Count -Force

        $ConsolidatedRecords += $First
    }

    # --------------------------------------------------------
    # 11. Validate taxonomy and country evidence
    # --------------------------------------------------------

    foreach ($Record in $ConsolidatedRecords) {
        $Record | Add-Member -NotePropertyName TaxonomyVerified `
            -NotePropertyValue ($Record.TaxonomyID -eq [string]$TaxonomyID) -Force

        $Record | Add-Member -NotePropertyName DiscoveryReviewStatus `
            -NotePropertyValue "Requires review" -Force

        if ($Record.TaxonomyID -ne [string]$TaxonomyID) {
            $Record.DiscoveryReviewStatus = "Taxonomy mismatch"
        }
        elseif ($Record.CountryConflict) {
            $Record.DiscoveryReviewStatus = "Conflicting country evidence"
        }
        elseif (-not $Record.CountryVerified) {
            $Record.DiscoveryReviewStatus = "Country evidence missing or mismatched"
        }
        elseif ($Record.Collection_Date_Eligibility -like "Outside*") {
            $Record.DiscoveryReviewStatus = "Historical - outside study period"
        }
        elseif ($Record.Collection_Date_Eligibility -like "Unresolved*") {
            $Record.DiscoveryReviewStatus = "Date unresolved - retain for review"
        }
        else {
            $Record.DiscoveryReviewStatus = "Candidate - further eligibility review"
        }
    }

    # --------------------------------------------------------
    # 12. Export timestamped discovery outputs
    # --------------------------------------------------------

    $CandidateFile = Join-Path $ManifestDirectory "NCBI_BioSample_Candidates_v2_$RunID.csv"
    $SearchManifestFile = Join-Path $ManifestDirectory "NCBI_BioSample_Search_Manifest_v2_$RunID.csv"
    $ReportFile = Join-Path $ReportDirectory "NCBI_BioSample_Discovery_Report_v2_$RunID.txt"
    $ChecksumFile = Join-Path $ManifestDirectory "NCBI_BioSample_SHA256_v2_$RunID.csv"

    foreach ($OutputPath in @(
        $CandidateFile,
        $SearchManifestFile,
        $ReportFile,
        $ChecksumFile
    )) {
        if (Test-Path -LiteralPath $OutputPath) {
            throw "Output already exists; refusing to overwrite: $OutputPath"
        }
    }

    $ConsolidatedRecords |
        Export-Csv -LiteralPath $CandidateFile -NoTypeInformation -Encoding UTF8

    $SearchManifest |
        Export-Csv -LiteralPath $SearchManifestFile -NoTypeInformation -Encoding UTF8

    $VerifiedCount = @($ConsolidatedRecords | Where-Object { $_.CountryVerified }).Count
    $UnverifiedCount = @($ConsolidatedRecords | Where-Object { -not $_.CountryVerified }).Count
    $TaxonomyCount = @($ConsolidatedRecords | Where-Object { $_.TaxonomyVerified }).Count
    $MissingDateCount = @($ConsolidatedRecords | Where-Object { $_.Collection_Date_Status -eq "Missing" }).Count
    $UnresolvedDateCount = @($ConsolidatedRecords | Where-Object { $_.Collection_Date_Eligibility -like "Unresolved*" }).Count
    $WithinPeriodCount = @($ConsolidatedRecords | Where-Object { $_.Collection_Date_Eligibility -like "Within study period*" }).Count
    $HistoricalCount = @($ConsolidatedRecords | Where-Object { $_.Collection_Date_Eligibility -eq "Outside study period" }).Count
    $CountryConflictCount = @($ConsolidatedRecords | Where-Object { $_.CountryConflict }).Count

    $ReportLines = @(
        "NCBI BIOSAMPLE COUNTRY DISCOVERY V2",
        "===================================",
        "Run ID: $RunID",
        "Run timestamp: $($RunTime.ToString('o'))",
        "Database: NCBI BioSample",
        "Organism: $ScientificName",
        "Taxonomy ID: $TaxonomyID",
        "Study period: 2017-01-01 through 2026",
        "Search cut-off: $($SearchCutoff.ToString('yyyy-MM-dd'))",
        "PowerShell version: $($PSVersionTable.PSVersion.ToString())",
        "PowerShell edition: $($PSVersionTable.PSEdition)",
        "",
        "COUNTRY SEARCH SUMMARY",
        "----------------------"
    )

    foreach ($Entry in $SearchManifest) {
        $ReportLines += "$($Entry.Country) | $($Entry.SearchAlias) | $($Entry.ResultCount) records"
    }

    $ReportLines += @(
        "",
        "RETRIEVAL AND VALIDATION",
        "-----------------------",
        "Unique BioSample accessions: $($ConsolidatedRecords.Count)",
        "Fetched records with missing BioSample accession: $($MissingAccessionRecords.Count)",
        "Taxonomy verified: $TaxonomyCount",
        "Country verified: $VerifiedCount",
        "Country unverified: $UnverifiedCount",
        "Conflicting country evidence: $CountryConflictCount",
        "Missing collection dates: $MissingDateCount",
        "Unresolved collection dates: $UnresolvedDateCount",
        "Within study period/year bracket: $WithinPeriodCount",
        "Outside study period: $HistoricalCount",
        "",
        "IMPORTANT INTERPRETATION",
        "------------------------",
        "These are BioSample discovery records, not a final independent-isolate count.",
        "Multiple BioSample records may still represent related or duplicate biological material.",
        "A BioSample record does not establish the availability of a genome assembly or raw reads.",
        "Missing and unresolved collection dates are retained for review.",
        "Collection dates are not inferred from sequencing, submission, assembly-release or publication dates.",
        "No final genome quality-control thresholds have been applied.",
        "",
        "OUTPUTS",
        "-------",
        "Candidate manifest: $CandidateFile",
        "Search manifest: $SearchManifestFile",
        "Raw responses: $RawDirectory",
        "Transcript: $TranscriptFile",
        "",
        "Status: DISCOVERY COMPLETED - REQUIRES DOWNSTREAM REVIEW"
    )

    $ReportLines += "Transcript checksum: Not included; transcript remains open during checksum generation."
    $ReportLines += "SHA-256 checksum manifest: $ChecksumFile"
    $ReportLines | Set-Content -LiteralPath $ReportFile -Encoding UTF8

    # Hash raw responses, request sidecars, source manifests,
    # report, configuration and the executing script.
    $FilesToHash = @()

    $FilesToHash += @(
        Get-ChildItem -LiteralPath $RawDirectory -File -Recurse
    )

    $FilesToHash += @(
        Get-Item -LiteralPath $CandidateFile
        Get-Item -LiteralPath $SearchManifestFile
        Get-Item -LiteralPath $ReportFile
        Get-Item -LiteralPath (Join-Path $ProjectRoot "config\project_config.yaml")
        Get-Item -LiteralPath $PSCommandPath
    )

    $ChecksumRows = foreach ($File in $FilesToHash) {
        $Hash = Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256

        [pscustomobject]@{
            File = $File.FullName
            FileName = $File.Name
            LengthBytes = $File.Length
            SHA256 = $Hash.Hash
        }
    }

    $ChecksumRows |
        Export-Csv -LiteralPath $ChecksumFile -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "DISCOVERY COMPLETED" -ForegroundColor Green
    Write-Host "Unique BioSample accessions: $($ConsolidatedRecords.Count)"
    Write-Host "Country verified: $VerifiedCount"
    Write-Host "Country unverified: $UnverifiedCount"
    Write-Host "Missing dates: $MissingDateCount"
    Write-Host "Unresolved dates: $UnresolvedDateCount"
    Write-Host ""
    Write-Host "Candidate manifest: $CandidateFile"
    Write-Host "Search manifest: $SearchManifestFile"
    Write-Host "Report: $ReportFile"
}
finally {
    Stop-Transcript | Out-Null
}





