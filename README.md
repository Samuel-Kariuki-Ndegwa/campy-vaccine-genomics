# Campy Vaccine Genomics

**A reproducible whole-genome sequencing (WGS) population genomics and vaccine-antigen research pipeline for *Campylobacter jejuni* in East Africa.**

**Project lead:** Samuel Ndegwa  
**Study countries:** Kenya, Ethiopia, Tanzania and Uganda  
**Collection period:** 1 January 2017 onwards  
**Project status:** Pipeline development

---

## 1. Project overview

This project aims to establish a reproducible genomic dataset of *Campylobacter jejuni* isolates collected in Kenya, Ethiopia, Tanzania and Uganda from 1 January 2017 onwards.

The project will integrate publicly available whole-genome sequencing data from multiple sources, harmonise isolate-level metadata, investigate missing collection-date information using linked publications, reconcile duplicate records and perform genome quality assessment.

The resulting dataset will support population genomic analyses and evidence-based prioritisation of potential *C. jejuni* vaccine antigens.

The pipeline is designed to be independently executable and verifiable by research collaborators.

## 2. Study scope

| Parameter | Definition |
|---|---|
| Organism | *Campylobacter jejuni* |
| NCBI taxonomy ID | 197 |
| Countries | Kenya, Ethiopia, Tanzania and Uganda |
| Collection start date | 1 January 2017 |
| Collection end date | Database search cut-off date, recorded for each run |
| Primary data type | Whole-genome sequencing |
| Biological unit | Independent bacterial isolate |

The geographic restriction will be applied as early as possible during database searches and metadata retrieval.

Records with uncertain geographic or temporal information will be retained for assessment rather than silently discarded.

## 3. Data sources

The pipeline will investigate the following public resources:

- **NCBI Assembly:** Existing genome assemblies and associated metadata.
- **NCBI BioSample:** Biological sample metadata and accession relationships.
- **NCBI SRA:** Whole-genome sequencing run metadata and raw sequencing reads.
- **PubMLST:** *Campylobacter* isolate characterisation records and available genome assemblies.
- **ENA:** Supplementary access to relevant sequencing records and read data.
- **Scientific publications:** Recovery and verification of collection dates and isolate-level metadata missing from sequence databases.

Records obtained from different databases will be reconciled to avoid counting the same isolate more than once.

## 4. Collection-date recovery

The primary collection period begins on 1 January 2017.

Where collection dates are missing or incomplete in sequence database records, the pipeline will investigate linked publications, supplementary datasets and study records.

Date evidence will be classified as follows:

- **Category A:** Exact collection date provided in sequence database metadata.
- **Category B:** Exact collection date recovered from a linked publication or supplementary dataset and matched to the isolate.
- **Category C:** Study-level collection period established, but individual isolate collection date unavailable.
- **Category D:** No reliable collection-date evidence identified.

Study-level collection periods will not be presented as exact isolate-level dates.

Records with unresolved dates will remain identifiable in the metadata and review registers.

## 5. WGS data requirements

The project will identify and manage two forms of WGS data:

1. **Genome assemblies:** Assembled nucleotide sequences, principally in FASTA format.
2. **Raw sequencing reads:** Whole-genome sequencing reads, principally in FASTQ format.

Where both data types exist for the same isolate, their relationships will be retained.

Raw reads will be retrieved selectively where required, including for isolates without suitable existing genome assemblies.

## 6. Pipeline workflow

The project will follow this sequence:

1. Define and document study parameters.
2. Search NCBI Assembly using the target organism, countries and study period.
3. Retrieve relevant NCBI BioSample metadata.
4. Identify associated NCBI SRA WGS records.
5. Retrieve relevant PubMLST records and available assemblies.
6. Search ENA for supplementary WGS records.
7. Recover missing collection dates from publications and supplementary datasets.
8. Harmonise metadata across data sources.
9. Reconcile accessions and identify duplicate isolates.
10. Retrieve selected genome assemblies and raw sequencing reads.
11. Assemble selected raw sequencing reads where required.
12. Perform genome identity and quality assessments.
13. Generate final isolate-level cohort and sequence manifests.

Each stage will produce documented inputs, outputs, validation checks and execution logs.

## 7. Reproducibility and validation

The pipeline will be developed with the following principles:

- Country and date restrictions are defined centrally.
- Original source metadata and accession identifiers are preserved.
- Database search dates and retrieval parameters are recorded.
- Software versions and analysis parameters are documented.
- Intermediate outputs are retained where scientifically useful.
- Scripts are designed to be resumable and avoid silent overwriting.
- Duplicate identification is performed at the biological-isolate level.
- Inclusion and exclusion decisions are documented.
- Validation reports are generated at each major stage.

Only validated and approved scripts will be incorporated into the main pipeline.

## 8. Repository structure

```text
campy-vaccine-genomics/
│
├── config/
├── scripts/
├── data/
│   ├── raw/
│   ├── metadata/
│   └── sequences/
├── results/
├── logs/
├── documentation/
└── environment/
```

Large sequencing files and other generated datasets may be maintained in appropriate external research storage. Their accessions, provenance, checksums and retrieval instructions will be documented in this repository.

## 9. Installation and execution

Installation instructions, software dependencies and the recommended execution sequence will be added as the pipeline modules are developed and validated.

The intended workflow will support execution by collaborators on compatible Windows and Linux environments using a documented software environment and a central project configuration file.

## 10. Collaboration

The repository is intended to support transparent research collaboration, independent validation and reproducibility.

Collaborators should:

- Use the documented project configuration.
- Follow the numbered execution sequence.
- Preserve original database metadata.
- Document changes to analysis parameters.
- Report errors and validation outcomes.
- Avoid replacing approved pipeline scripts without review.

## 11. Project status

**Current milestone:** Initial repository and project directory structure established.

The next development milestone is the central project configuration and the first country-restricted NCBI Assembly metadata retrieval module.

---

**Repository:** `campy-vaccine-genomics`  
**Project lead:** Samuel Ndegwa# campy-vaccine-genomics
Reproducible WGS population genomics and vaccine antigen research in Campylobacter jejuni from East Africa
