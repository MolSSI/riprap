# Feature: Pull Missing Basis Set from Basis Set Exchange

This feature provides a function for fetching Gaussian basis sets needed for electronic structure
calculations. Basis set files are stored locally under `data/basis`. When a required basis set is
not cached, the function downloads it from the Basis Set Exchange (BSE) REST API and saves it for
future use. If `data/basis` (or any subdirectory) does not exist, it is created automatically.

## Feature API

### Functions

- `fetch_basis(element: &str, basis_name: &str) -> Result<PathBuf, BseError>`
  - Validates the element symbol against the known periodic table (elements 1–118).
  - Normalizes `basis_name` to lowercase and `element` to title case before use in file paths and
    API requests.
  - Checks whether a valid cached file already exists at `data/basis/{basis_name}/{element}.json`.
  - If the cache is missing or corrupt, downloads the basis set data for the given element from the
    BSE REST API in QCSchema (JSON) format, creating any missing directories, and overwrites the
    cache file with the fresh response.
  - Returns the `PathBuf` to the cached file on success.

### Types

- `BseError` — error type returned by `fetch_basis`. Must include at minimum:
  - `InvalidElement(String)` — the element symbol does not correspond to a known element (Z = 1–118).
  - `InvalidBasisSetName(String)` — the basis set name is empty or otherwise malformed before any
    API request is made.
  - `ElementNotInBasisSet { element: String, basis_name: String }` — the basis set exists but does
    not include data for this element.
  - `UnknownBasisSet(String)` — the BSE does not recognise the basis set name (HTTP 404).
  - `NetworkError(String)` — a network or HTTP-level failure (unreachable host, timeout, or
    non-200/404 status code).
  - `IoError(String)` — a filesystem operation failed (directory creation, file write, or file read).
  - `InvalidResponse(String)` — the BSE returned a response that could not be parsed as valid JSON.

## BSE API Details

- Base URL: `https://www.basissetexchange.org`
- Download endpoint: `GET /api/basis/{basis_name}/format/qcschema?elements={element}`
- The API is case-insensitive for both basis names and element symbols.
- A 404 response indicates the basis set name is not known to the BSE.
- A 200 response with an empty `elements` field in the JSON body indicates the element is not
  included in the specified basis set.

## Cache Validation

An existing file is considered valid if and only if:

- It exists at the expected path.
- Its size is greater than zero bytes.
- Its contents parse successfully as JSON.

If any condition fails the file is treated as corrupt and a fresh download is attempted. A corrupt
file must be overwritten by the fresh download; the function must not return an error solely because
a corrupt cache file was found.

---

## Gherkin Scenarios

```gherkin
Feature: Fetch basis set from Basis Set Exchange

  Background:
    Given the BSE base URL is "https://www.basissetexchange.org"

  # --- Happy paths ---

  Scenario: Download a basis set that is not cached
    Given the file "data/basis/sto-3g/H.json" does not exist
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then the file "data/basis/sto-3g/H.json" is created
    And the file contains the JSON response returned by the BSE API
    And fetch_basis returns Ok with the path "data/basis/sto-3g/H.json"

  Scenario: Return cached file when a valid cache exists
    Given a non-empty, valid JSON file exists at "data/basis/sto-3g/H.json"
    When fetch_basis("H", "sto-3g") is called
    Then no HTTP request is made to the BSE API
    And fetch_basis returns Ok with the path "data/basis/sto-3g/H.json"

  Scenario: Create data/basis directory if it does not exist
    Given the directory "data/basis" does not exist
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then the directory "data/basis/sto-3g" is created
    And the file "data/basis/sto-3g/H.json" is created

  Scenario: Create basis-set subdirectory if it does not exist
    Given the directory "data/basis" exists
    And the directory "data/basis/sto-3g" does not exist
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then the directory "data/basis/sto-3g" is created
    And the file "data/basis/sto-3g/H.json" is created

  Scenario: Basis set name is normalized to lowercase in the file path
    Given the file "data/basis/sto-3g/H.json" does not exist
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "STO-3G") is called
    Then the file is saved to "data/basis/sto-3g/H.json"
    And fetch_basis returns Ok with the path "data/basis/sto-3g/H.json"

  Scenario: Element symbol is normalized to title case in the file path
    Given the file "data/basis/sto-3g/H.json" does not exist
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("h", "sto-3g") is called
    Then the file is saved to "data/basis/sto-3g/H.json"
    And fetch_basis returns Ok with the path "data/basis/sto-3g/H.json"

  # --- Input validation ---

  Scenario: Reject an unrecognised element symbol
    When fetch_basis("Xx", "sto-3g") is called
    Then no HTTP request is made to the BSE API
    And fetch_basis returns Err(BseError::InvalidElement("Xx"))

  Scenario: Reject an empty element symbol
    When fetch_basis("", "sto-3g") is called
    Then no HTTP request is made to the BSE API
    And fetch_basis returns Err(BseError::InvalidElement(""))

  Scenario: Reject an empty basis set name
    When fetch_basis("H", "") is called
    Then no HTTP request is made to the BSE API
    And fetch_basis returns Err(BseError::InvalidBasisSetName(""))

  # --- BSE API error responses ---

  Scenario: Basis set name is not known to the BSE
    Given the file "data/basis/unknown-basis/H.json" does not exist
    And the BSE API will return HTTP 404 for element "H" and basis "unknown-basis"
    When fetch_basis("H", "unknown-basis") is called
    Then fetch_basis returns Err(BseError::UnknownBasisSet("unknown-basis"))
    And no file is written to disk

  Scenario: Element is not included in the requested basis set
    Given the file "data/basis/sto-3g/Au.json" does not exist
    And the BSE API returns HTTP 200 with an empty "elements" field for element "Au" and basis "sto-3g"
    When fetch_basis("Au", "sto-3g") is called
    Then fetch_basis returns Err(BseError::ElementNotInBasisSet { element: "Au", basis_name: "sto-3g" })
    And no file is written to disk

  Scenario: BSE API returns an unexpected HTTP status code
    Given the file "data/basis/sto-3g/H.json" does not exist
    And the BSE API returns HTTP 500 for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then fetch_basis returns Err(BseError::NetworkError(_))
    And no file is written to disk

  Scenario: BSE API is unreachable
    Given the file "data/basis/sto-3g/H.json" does not exist
    And the BSE API host is unreachable
    When fetch_basis("H", "sto-3g") is called
    Then fetch_basis returns Err(BseError::NetworkError(_))
    And no file is written to disk

  Scenario: BSE API returns a response that is not valid JSON
    Given the file "data/basis/sto-3g/H.json" does not exist
    And the BSE API returns HTTP 200 with a non-JSON body for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then fetch_basis returns Err(BseError::InvalidResponse(_))
    And no file is written to disk

  # --- Cache validation ---

  Scenario: Re-download when cached file is empty
    Given an empty file exists at "data/basis/sto-3g/H.json"
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then the BSE API is queried
    And the file "data/basis/sto-3g/H.json" is overwritten with the fresh response
    And fetch_basis returns Ok with the path "data/basis/sto-3g/H.json"

  Scenario: Re-download when cached file contains invalid JSON
    Given a file at "data/basis/sto-3g/H.json" containing malformed JSON
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then the BSE API is queried
    And the file "data/basis/sto-3g/H.json" is overwritten with the fresh response
    And fetch_basis returns Ok with the path "data/basis/sto-3g/H.json"

  # --- Filesystem errors ---

  Scenario: Filesystem error when creating the directory
    Given the directory "data/basis/sto-3g" cannot be created due to a permissions error
    When fetch_basis("H", "sto-3g") is called
    Then fetch_basis returns Err(BseError::IoError(_))

  Scenario: Filesystem error when writing the downloaded file
    Given the directory "data/basis/sto-3g" exists
    And the file "data/basis/sto-3g/H.json" cannot be written due to a permissions error
    And the BSE API will return a valid QCSchema JSON response for element "H" and basis "sto-3g"
    When fetch_basis("H", "sto-3g") is called
    Then fetch_basis returns Err(BseError::IoError(_))
```
