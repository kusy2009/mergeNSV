# mergeNSV (Latest version 0.1.0 on 05October2026)

mergeNSV is a SAS package with one macro, `%merge_nsv()`, that merges the non-standard variables (NSVs) of an SDTM domain onto that domain from whichever representation the study provides: `SUPP<domain>` as defined by SDTMIG 3.x, or `NS<domain>` as defined by SDTM v3.0 / SDTMIG v4.0. A program calls it the same way for a 3.x study and a 4.0 study, and keeps the call when a study collected no non-standard variable at all.

The package has no dependency on any other macro or package.

> **Status:** pre-release. The NS-- structure is the one in the SDTM v3.0 / SDTMIG v4.0 public-review draft (review closed 06-April-2026, publication targeted Q4 2026) and will be re-checked against the published standard. Publication of this repository is subject to the author's organisation's open-source approval.

---

## %merge_nsv()

### Purpose:
   Merge an SDTM domain's non-standard variables onto the domain. The macro looks in the input library for `SUPP<domain>` and `NS<domain>`, takes the one that exists, and copies the domain through unchanged when neither contributes a row.

### Parameters:
~~~sas
 - `inlib`   (optional, default=SDTM) : Input library holding the domain and its SUPP-- or NS-- dataset.
 - `domain`  (required)               : SDTM domain to merge onto, e.g. AE, DM, LB, FAMH.
 - `outdset` (required)               : Output dataset, one- or two-level name.
 - `nsvvars` (optional, default=all)  : Space-separated list of the non-standard variables to merge,
                                        e.g. AESOSP AETRTEM. Blank merges all of them.
 - `debug`   (optional, default=N)    : Y keeps the work._nsv_* intermediate datasets, including the
                                        orphan-row datasets; N deletes them.
~~~

### Example usage:
~~~sas
%* Every non-standard variable of AE, from SDTM.SUPPAE or SDTM.NSAE - whichever exists;
%merge_nsv(domain=AE, outdset=work.ae1);

%* Only the named non-standard variables;
%merge_nsv(domain=AE, outdset=work.ae1, nsvvars=AESOSP AETRTEM);

%* A domain with no sequence variable, and a domain read from another library;
%merge_nsv(domain=DM, outdset=work.dm1);
%merge_nsv(inlib=sdtmv4, domain=LB, outdset=work.lb1, debug=Y);
~~~

### Behaviour worth knowing:
- **SUPP--** (vertical, one row per value) may link rows to the parent by different IDVARs. Each distinct IDVAR is transposed and merged as its own group; IDVARVAL is converted to the type of the parent variable it links by; rows with a blank IDVAR (DM) link by STUDYID and USUBJID alone. Only populated QVAL rows are used. QNAM, QLABEL, QVAL, IDVAR, IDVARVAL and RDOMAIN never reach the output.
- **NS--** (horizontal, one row per parent record) merges without a transpose. IDVAR is read from the data, so a split domain (`NSFAMH`, keyed by FASEQ) and a domain with a null IDVAR (`NSDM`) are both handled; IDVARVLN is renamed onto the parent key. RDOMAIN, IDVAR and IDVARVLN are dropped as linkage metadata.
- A study carries one representation. If both exist, NS-- is taken and an ALERT is written. A representation with nothing populated counts as absent.
- Rows that match no parent record are not merged; they are counted, reported as an ALERT and kept in `work._nsv_orph<n>` (SUPP--) or `work._nsv_orphan` (NS--) when `debug=Y`. A key that is not unique in NS-- is reported as an ALERT because the merge repeats the parent record.
- The macro merges non-standard variables and nothing else: no subject-level merge.

 Author:             Saikrishnareddy Yengannagari  
 Latest update Date: 2026-10-05  
