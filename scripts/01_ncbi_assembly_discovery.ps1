# ============================================================
# CAMPY VACCINE GENOMICS
# STAGE 03A: NCBI ASSEMBLY DISCOVERY
# ============================================================

$ErrorActionPreference = "Stop"

$ProjectRoot = "E:\campy-vaccine-genomics"

$TaxonomyID = 197
$Organism = "Campylobacter jejuni"
$BatchSize = 200

$RunTimestamp = Get-Date -Format "yyyyMMddTHHmmss"
$SearchDateTime = (Get-Date).ToString("o")

$RawDirectory = Join-Path $ProjectRoot "data\raw\ncbi_assembly"
$ManifestDirectory = Join-Path $ProjectRoot "data\metadata\source_manifests"
$ResultsDirectory = Join-Path $ProjectRoot "results\database_searches"
$LogDirectory = Join-Path $ProjectRoot "logs"

$SearchFile = Join-Path $RawDirectory "Assembly_ESearch_$RunTimestamp.json"
$OutputCSV = Join-Path $ManifestDirectory "NCBI_Assembly_Discovery_$RunTimestamp.csv"
$ManifestCSV = Join-Path $ManifestDirectory "NCBI_Assembly_Search_Manifest_$RunTimestamp.csv"
$ReportFile = Join-Path $ResultsDirectory "NCBI_Assembly_Search_Report_$RunTimestamp.txt"
$LogFile = Join-Path $LogDirectory "NCBI_Assembly_Search_$RunTimestamp.log"

$BaseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

# ------------------------------------------------------------
# 1. VALIDATE OUTPUT PATHS
# ------------------------------------------------------------

$OutputFiles = @(
    $SearchFile,
    $OutputCSV,
    $ManifestCSV,
    $ReportFile,
    $LogFile
)

foreach ($File in $OutputFiles) {
    if (Test-Path -LiteralPath $File) {
        throw "Output already exists. No overwrite allowed: $File"
    }
}

# ------------------------------------------------------------
# 2. INITIALISE LOGGING
# ------------------------------------------------------------

Start-Transcript -LiteralPath $LogFile

try {

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "NCBI ASSEMBLY DISCOVERY"
    Write-Host "=============================================="

    Write-Host "Organism: $Organism"
    Write-Host "Taxonomy ID: $TaxonomyID"
    Write-Host "Search time: $SearchDateTime"
    Write-Host ""

    # --------------------------------------------------------
    # 3. SEARCH NCBI ASSEMBLY
    # --------------------------------------------------------

    $Query = "txid$TaxonomyID[Organism:exp]"

    $EncodedQuery = [uri]::EscapeDataString($Query)

    $SearchURL = "$BaseURL/esearch.fcgi?db=assembly&term=$EncodedQuery&retmax=10000&retmode=json&tool=CampyVaccineGenomics"

    Write-Host "Searching NCBI Assembly..."

    $SearchResponse = Invoke-RestMethod `
        -Uri $SearchURL `
        -Method Get `
        -TimeoutSec 180

    $SearchResponse |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $SearchFile -Encoding UTF8

    $Count = [int]$SearchResponse.esearchresult.count

    $UIDs = @($SearchResponse.esearchresult.idlist)

    Write-Host "NCBI Assembly records found: $Count"

    if ($Count -eq 0) {
        throw "No Assembly records returned. Review the search query before proceeding."
    }

    if ($Count -gt 10000) {
        throw "More than 10,000 records returned. A paginated retrieval strategy is required."
    }

    if ($UIDs.Count -ne $Count) {
        throw "Search count and retrieved UID count do not match."
    }

    # --------------------------------------------------------
    # 4. RETRIEVE ASSEMBLY SUMMARIES IN BATCHES
    # --------------------------------------------------------

    $AllRecords = [System.Collections.Generic.List[object]]::new()

    $BatchNumber = 0
    $TotalBatches = [math]::Ceiling($UIDs.Count / $BatchSize)

    for ($StartIndex = 0; $StartIndex -lt $UIDs.Count; $StartIndex += $BatchSize) {

        $BatchNumber++

        $EndIndex = [math]::Min(
            $StartIndex + $BatchSize - 1,
            $UIDs.Count - 1
        )

        $BatchUIDs = @(
            $UIDs[$StartIndex..$EndIndex]
        )

        $BatchFile = Join-Path $RawDirectory (
            "Assembly_ESummary_Batch_{0:D4}_$RunTimestamp.xml" -f $BatchNumber
        )

        if (Test-Path -LiteralPath $BatchFile) {
            throw "Batch output already exists: $BatchFile"
        }

        $IDString = $BatchUIDs -join ","

        $SummaryURL = "$BaseURL/esummary.fcgi?db=assembly&id=$IDString&retmode=xml&tool=CampyVaccineGenomics"

        Write-Host "Retrieving batch $BatchNumber of $TotalBatches..."

        $SummaryResponse = Invoke-WebRequest `
            -Uri $SummaryURL `
            -Method Get `
            -TimeoutSec 180 `
            -UseBasicParsing

        $SummaryResponse.Content |
            Set-Content -LiteralPath $BatchFile -Encoding UTF8

        [xml]$XML = $SummaryResponse.Content

        $Documents = $XML.SelectNodes("//DocumentSummary")

        if ($Documents.Count -ne $BatchUIDs.Count) {
            throw "Batch ${BatchNumber}: returned summary count does not match requested UID count."
        }

        foreach ($Document in $Documents) {

            $Record = [ordered]@{
                Assembly_UID = $Document.GetAttribute("uid")
                Assembly_Accession = $null
                Assembly_Name = $null
                Organism = $null
                Species_Name = $null
                Taxonomy_ID = $null
                BioSample_UID = $null
                BioSample_Accession = $null
                BioProject_UID = $null
                BioProject_Accession = $null
                Submission_Date = $null
                Last_Update_Date = $null
                Assembly_Release_Date = $null
                Assembly_Update_Date = $null
                Assembly_Status = $null
                Assembly_Level = $null
                RefSeq_Category = $null
                GenBank_FTP_Path = $null
                RefSeq_FTP_Path = $null
                WGS_Project = $null
                Coverage = $null
                Submitter = $null
                Sequencing_Technology = $null
                Country_Verification = "Pending BioSample metadata"
                Collection_Date_Verification = "Pending BioSample metadata"
                Search_Timestamp = $SearchDateTime
                Source_Database = "NCBI Assembly"
            }

            foreach ($Field in @(
                "AssemblyAccession",
                "AssemblyName",
                "Organism",
                "SpeciesName",
                "Taxid",
                "BioSampleId",
                "BioSampleAccn",
                "BioProjectId",
                "BioProjectAccn",
                "SubmissionDate",
                "LastUpdateDate",
                "AsmReleaseDate",
                "AsmUpdateDate",
                "AssemblyStatus",
                "AssemblyLevel",
                "RefSeq_category",
                "FtpPath_GenBank",
                "FtpPath_RefSeq",
                "WGS",
                "Coverage",
                "SubmitterOrganization",
                "SeqTech"
            )) {

                $Node = $Document.SelectSingleNode($Field)

                if ($null -ne $Node) {

                    $Value = $Node.InnerText

                    switch ($Field) {
                        "AssemblyAccession" {
                            $Record.Assembly_Accession = $Value
                        }
                        "AssemblyName" {
                            $Record.Assembly_Name = $Value
                        }
                        "Organism" {
                            $Record.Organism = $Value
                        }
                        "SpeciesName" {
                            $Record.Species_Name = $Value
                        }
                        "Taxid" {
                            $Record.Taxonomy_ID = $Value
                        }
                        "BioSampleId" {
                            $Record.BioSample_UID = $Value
                        }
                        "BioSampleAccn" {
                            $Record.BioSample_Accession = $Value
                        }
                        "BioProjectId" {
                            $Record.BioProject_UID = $Value
                        }
                        "BioProjectAccn" {
                            $Record.BioProject_Accession = $Value
                        }
                        "SubmissionDate" {
                            $Record.Submission_Date = $Value
                        }
                        "LastUpdateDate" {
                            $Record.Last_Update_Date = $Value
                        }
                        "AsmReleaseDate" {
                            $Record.Assembly_Release_Date = $Value
                        }
                        "AsmUpdateDate" {
                            $Record.Assembly_Update_Date = $Value
                        }
                        "AssemblyStatus" {
                            $Record.Assembly_Status = $Value
                        }
                        "AssemblyLevel" {
                            $Record.Assembly_Level = $Value
                        }
                        "RefSeq_category" {
                            $Record.RefSeq_Category = $Value
                        }
                        "FtpPath_GenBank" {
                            $Record.GenBank_FTP_Path = $Value
                        }
                        "FtpPath_RefSeq" {
                            $Record.RefSeq_FTP_Path = $Value
                        }
                        "WGS" {
                            $Record.WGS_Project = $Value
                        }
                        "Coverage" {
                            $Record.Coverage = $Value
                        }
                        "SubmitterOrganization" {
                            $Record.Submitter = $Value
                        }
                        "SeqTech" {
                            $Record.Sequencing_Technology = $Value
                        }
                    }
                }
            }

            $AllRecords.Add([pscustomobject]$Record)
        }

        Start-Sleep -Milliseconds 400
    }

    # --------------------------------------------------------
    # 5. VALIDATE CONSOLIDATED RESULTS
    # --------------------------------------------------------

    $UniqueUIDs = @(
        $AllRecords |
        Select-Object -ExpandProperty Assembly_UID -Unique
    )

    $UniqueAccessions = @(
        $AllRecords |
        Where-Object { $_.Assembly_Accession } |
        Select-Object -ExpandProperty Assembly_Accession -Unique
    )

    $MissingAccession = @(
        $AllRecords |
        Where-Object { [string]::IsNullOrWhiteSpace($_.Assembly_Accession) }
    ).Count

    $MissingBioSample = @(
        $AllRecords |
        Where-Object { [string]::IsNullOrWhiteSpace($_.BioSample_Accession) }
    ).Count

    $ExactSpecies = @(
        $AllRecords |
        Where-Object { $_.Organism -eq "Campylobacter jejuni" }
    ).Count

    $OtherOrganismLabels = @(
        $AllRecords |
        Where-Object { $_.Organism -ne "Campylobacter jejuni" }
    ).Count

    if ($AllRecords.Count -ne $Count) {
        throw "Consolidated record count does not match NCBI search count."
    }

    if ($UniqueUIDs.Count -ne $AllRecords.Count) {
        throw "Duplicate Assembly UIDs detected."
    }

    if ($UniqueAccessions.Count -ne $AllRecords.Count) {
        throw "Missing or duplicate Assembly accessions detected. Review before proceeding."
    }

    # --------------------------------------------------------
    # 6. SAVE CONSOLIDATED ASSEMBLY METADATA
    # --------------------------------------------------------

    $AllRecords |
        Export-Csv -LiteralPath $OutputCSV -NoTypeInformation -Encoding UTF8

    # --------------------------------------------------------
    # 7. CREATE SEARCH MANIFEST
    # --------------------------------------------------------

    $Manifest = [pscustomobject]@{
        Project = "Campy Vaccine Genomics"
        Source_Database = "NCBI Assembly"
        Organism = $Organism
        Taxonomy_ID = $TaxonomyID
        Search_Query = $Query
        Search_Timestamp = $SearchDateTime
        NCBI_Records_Reported = $Count
        Records_Retrieved = $AllRecords.Count
        Unique_Assembly_UIDs = $UniqueUIDs.Count
        Unique_Assembly_Accessions = $UniqueAccessions.Count
        Exact_Organism_Label_Count = $ExactSpecies
        Other_Organism_Label_Count = $OtherOrganismLabels
        Missing_Assembly_Accessions = $MissingAccession
        Missing_BioSample_Accessions = $MissingBioSample
        Batch_Size = $BatchSize
        Number_Of_Batches = $TotalBatches
        Country_Filter = "Not applied at Assembly summary stage"
        Collection_Date_Filter = "Not applied at Assembly summary stage"
        Sequence_Downloaded = $false
        Search_Response_File = $SearchFile
        Consolidated_Metadata_File = $OutputCSV
    }

    $Manifest |
        Export-Csv -LiteralPath $ManifestCSV -NoTypeInformation -Encoding UTF8

    # --------------------------------------------------------
    # 8. CREATE VALIDATION REPORT
    # --------------------------------------------------------

    $Report = @"
CAMPY VACCINE GENOMICS
STAGE 03A: NCBI ASSEMBLY DISCOVERY REPORT

Search timestamp: $SearchDateTime
Organism: $Organism
Taxonomy ID: $TaxonomyID
Search query: $Query

NCBI Assembly records reported: $Count
Records retrieved: $($AllRecords.Count)
Unique Assembly UIDs: $($UniqueUIDs.Count)
Unique Assembly accessions: $($UniqueAccessions.Count)

Exact organism label: $ExactSpecies
Other organism labels: $OtherOrganismLabels

Missing Assembly accessions: $MissingAccession
Missing BioSample accessions: $MissingBioSample

Batch size: $BatchSize
Batches retrieved: $TotalBatches

Country filtering: Pending linked BioSample metadata
Collection-date verification: Pending linked BioSample metadata
FASTA downloaded: No

Raw ESearch response:
$SearchFile

Consolidated metadata:
$OutputCSV

Search manifest:
$ManifestCSV

STATUS: PASSED
"@

    $Report |
        Set-Content -LiteralPath $ReportFile -Encoding UTF8

    # --------------------------------------------------------
    # 9. DISPLAY FINAL VALIDATION
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "STAGE 03A VALIDATION"
    Write-Host "=============================================="

    Write-Host "NCBI records: $Count"
    Write-Host "Retrieved records: $($AllRecords.Count)"
    Write-Host "Unique Assembly UIDs: $($UniqueUIDs.Count)"
    Write-Host "Unique Assembly accessions: $($UniqueAccessions.Count)"
    Write-Host "Exact organism labels: $ExactSpecies"
    Write-Host "Missing BioSample accessions: $MissingBioSample"

    Write-Host ""
    Write-Host "Consolidated CSV:"
    Write-Host $OutputCSV

    Write-Host ""
    Write-Host "Validation report:"
    Write-Host $ReportFile

    Write-Host ""
    Write-Host "STATUS: PASSED" -ForegroundColor Green

}
catch {

    Write-Host ""
    Write-Host "STAGE 03A FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    throw
}
finally {

    Stop-Transcript
}

