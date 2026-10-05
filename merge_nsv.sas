/*** HELP START ***//*

### Macro:
    %merge_nsv

### Purpose:
    Merge the non-standard variables (NSVs) of an SDTM domain onto that domain, from whichever
    representation the study provides: `SUPP<domain>` as defined by SDTMIG 3.x, or `NS<domain>` as
    defined by SDTM v3.0 / SDTMIG v4.0. The caller names the domain only. The macro looks for both
    datasets in the input library, takes the one that exists, and copies the domain through
    unchanged when neither contributes a row - so the call can stay in a program whether or not
    the study collected any non-standard variable, and whichever version of the standard the SDTM
    was built to.

### Parameters:

 - `inlib`   (optional, default=SDTM) : Input library holding the domain and its SUPP-- or NS-- dataset.
 - `domain`  (required)               : SDTM domain to merge onto, e.g. `AE`, `DM`, `LB`, `FAMH`.
                                        The macro looks for `SUPP<domain>` and `NS<domain>` itself.
 - `outdset` (required)               : Output dataset, one- or two-level name.
 - `nsvvars` (optional, default=all)  : Space-separated list of the non-standard variables to merge,
                                        e.g. `AESOSP AETRTEM`. Blank merges all of them.
 - `debug`   (optional, default=N)    : `Y` keeps the `work._nsv_*` intermediate datasets, including
                                        the orphan-row datasets; `N` deletes them.

### Sample code:

~~~sas
%* Every non-standard variable of AE, from SDTM.SUPPAE or SDTM.NSAE - whichever exists;
%merge_nsv(domain=AE, outdset=work.ae1);

%* Only the named non-standard variables;
%merge_nsv(domain=AE, outdset=work.ae1, nsvvars=AESOSP AETRTEM);

%* A domain with no sequence variable, and a domain read from another library;
%merge_nsv(domain=DM, outdset=work.dm1);
%merge_nsv(inlib=sdtmv4, domain=LB, outdset=work.lb1, debug=Y);
~~~

### Notes:

- **SUPP--** is vertical, one row per value, and its rows may be linked to the parent by
  different IDVARs. Each distinct IDVAR is transposed and merged as its own group; IDVARVAL is
  converted to the type of the parent variable it links by; rows with a blank IDVAR (DM) link by
  STUDYID and USUBJID alone. Only rows with a populated QVAL are used. QNAM, QLABEL, QVAL, IDVAR,
  IDVARVAL and RDOMAIN never reach the output.
- **NS--** is horizontal, one row per parent record, and merges without a transpose. IDVAR is
  read from the data rather than derived from the dataset name, so a split domain (`NSFAMH`,
  keyed by FASEQ) and a domain with a null IDVAR (`NSDM`) are both handled; IDVARVLN is renamed
  onto the parent key. RDOMAIN, IDVAR and IDVARVLN are linkage metadata and are dropped.
- A study carries one representation. If both exist, NS-- is taken and an ALERT is written. A
  representation that has nothing populated counts as absent.
- Rows that match no parent record are not merged: they are counted, reported as an ALERT, and
  kept in `work._nsv_orph<n>` (SUPP--) or `work._nsv_orphan` (NS--) when `debug=Y`. A key that
  is not unique in NS-- is reported as an ALERT, because the merge then repeats the parent record.
- The macro merges non-standard variables and nothing else - no subject-level merge - and has no
  dependency on any other macro or package.
- NS-- is defined in SDTM v3.0 / SDTMIG v4.0, whose public review closed on 06-April-2026 with
  publication targeted for Q4 2026. The structure read here is the public-review draft; re-check
  it against the published version.

### URL:

https://github.com/kusy2009/mergeNSV

---

Author:              Saikrishnareddy Yengannagari
Latest update Date:  2026-10-05

---

*//*** HELP END ***/

%macro merge_nsv( inlib   = SDTM,
                  domain  = ,
                  outdset = ,
                  nsvvars = ,
                  debug   = N
                );

%local _dom _supdsn _nsdsn _hassup _hasns _supobs _nsobs _parobs _err _suppfltr
       _dsid _vnum _vtype _idvarlst _nidvar _nblank _from _kv _keyvar
       _hasidvar _hasrdom _hasidv _hasidvn _hasqlabel _nsdsopt _txdrop
       _txbyvars _mgbyvars _supwhr _lastkey _norphan _ndupkey _i;

%let _err     = 0;
%let _hassup  = 0;
%let _hasns   = 0;
%let _supobs  = 0;
%let _nsobs   = 0;
%let _parobs  = 0;
%let _nidvar  = 0;
%let _nblank  = 0;

%put NOTE: merge_nsv 0.1.0 is merging the non-standard variables of %upcase(&inlib..&domain.).;

/*-----------------------------------------------------------------------------------------------/
    Verify the required parameters, then the parent domain and the variables every representation
    is linked by. One handle is opened on the parent to read its row count and its variables.
/-----------------------------------------------------------------------------------------------*/
%if %length(&domain.) = 0 %then %do;
    %put %str(ERR)%str(OR: the DOMAIN parameter is required but its value is not provided.);
    %let _err = 1;
%end;

%if %length(&outdset.) = 0 %then %do;
    %put %str(ERR)%str(OR: the OUTDSET parameter is required but its value is not provided.);
    %let _err = 1;
%end;

%if &_err. = 1 %then %return;

%let _dom    = %upcase(&domain.);
%let _supdsn = &inlib..supp&_dom.;
%let _nsdsn  = &inlib..ns&_dom.;

%if %sysfunc(exist(&inlib..&_dom.)) = 0 %then %do;
    %put %str(ERR)%str(OR: %upcase(&inlib..&_dom.) is required but does not exist.);
    %return;
%end;

%let _dsid = %sysfunc(open(&inlib..&_dom.));

%if &_dsid. = 0 %then %do;
    %put %str(ERR)%str(OR: %upcase(&inlib..&_dom.) cannot be opened. %sysfunc(sysmsg()));
    %return;
%end;

%let _parobs = %sysfunc(attrn(&_dsid., nlobs));

%if %sysfunc(varnum(&_dsid., studyid)) = 0 %then %do;
    %put %str(ERR)%str(OR: STUDYID is required in %upcase(&inlib..&_dom.) but does not exist.);
    %let _err = 1;
%end;

%if %sysfunc(varnum(&_dsid., usubjid)) = 0 %then %do;
    %put %str(ERR)%str(OR: USUBJID is required in %upcase(&inlib..&_dom.) but does not exist.);
    %let _err = 1;
%end;

%let _dsid = %sysfunc(close(&_dsid.));

%if &_err. = 1 %then %return;

%if &_parobs. = 0 %then
    %put %str(ALE)%str(RT: %upcase(&inlib..&_dom.) has 0 observations, so %upcase(&outdset.) has none either.);

/*-----------------------------------------------------------------------------------------------/
    Build the row filter for the SUPP-- representation, where a non-standard variable is a value
    of QNAM rather than a variable of its own.
/-----------------------------------------------------------------------------------------------*/
%if %length(&nsvvars.) = 0 %then %let _suppfltr = 1 eq 1;
%else %do;
    %let _suppfltr = ;
    %do _i = 1 %to %sysfunc(countw(&nsvvars., %str( )));
        %let _suppfltr = &_suppfltr. "%upcase(%scan(&nsvvars., &_i., %str( )))";
    %end;
    %let _suppfltr = qnam in (&_suppfltr.);
%end;

/*-----------------------------------------------------------------------------------------------/
    Establish which representation the study provides and how many rows it contributes. A row
    with no value contributes nothing, so it is left out of the count as well as out of the merge.
/-----------------------------------------------------------------------------------------------*/
%if %sysfunc(exist(&_supdsn.)) %then %let _hassup = 1;
%if %sysfunc(exist(&_nsdsn.))  %then %let _hasns  = 1;

%if (&_hassup. = 1) or (&_hasns. = 1) %then %do;
    proc sql noprint;
        %if &_hassup. = 1 %then %do;
            select count(*) into: _supobs from &_supdsn. where (&_suppfltr.) and qval ne ' ';
        %end;

        %if &_hasns. = 1 %then %do;
            select count(*) into: _nsobs from &_nsdsn.;
        %end;
    quit;
%end;

/*-----------------------------------------------------------------------------------------------/
    A study is built to one version of the standard, so it carries one representation or the
    other. Both at once is a data issue, and the newer representation is the one taken.
/-----------------------------------------------------------------------------------------------*/
%if (&_hassup. = 1) and (&_hasns. = 1) %then %do;
    %let _hassup = 0;
    %put %str(ALE)%str(RT: %upcase(&_supdsn.) and %upcase(&_nsdsn.) both exist but only one representation of the non-standard variables is expected. NS&_dom. is merged and SUPP&_dom. is ignored.);
%end;

/*-----------------------------------------------------------------------------------------------/
    A representation which contributes no row is treated as absent. When the caller named the
    variables to merge, none of them being there is worth reporting rather than passing over.
/-----------------------------------------------------------------------------------------------*/
%if (&_hassup. = 1) and (&_supobs. = 0) %then %do;
    %let _hassup = 0;
    %if %length(&nsvvars.) = 0 %then
        %put NOTE: %upcase(&_supdsn.) exists but has no populated QVAL, so there is nothing to merge.;
    %else
        %put %str(ALE)%str(RT: %upcase(&_supdsn.) has no populated QNAM among (%upcase(&nsvvars.)), so there is nothing to merge.);
%end;

%if (&_hasns. = 1) and (&_nsobs. = 0) %then %do;
    %let _hasns = 0;
    %put NOTE: %upcase(&_nsdsn.) exists but has 0 observations, so there is nothing to merge.;
%end;

/*-----------------------------------------------------------------------------------------------/
    With no non-standard variable to merge the domain is passed through unchanged, so that the
    call does not have to be removed from a program for a study which has none.
/-----------------------------------------------------------------------------------------------*/
%if (&_hassup. = 0) and (&_hasns. = 0) %then %do;
    %put NOTE: neither SUPP&_dom. nor NS&_dom. contributes a row, so %upcase(&inlib..&_dom.) is copied to %upcase(&outdset.) unchanged.;

    data &outdset.;
        set &inlib..&_dom.;
    run;

    %return;
%end;

%if &_hassup. = 1 %then %do;

    /*-------------------------------------------------------------------------------------------/
        The SUPP-- representation is vertical, so it has to be transposed onto the parent.

        SUPPQUAL allows the rows of one dataset to be linked to the parent by different
        variables, so QNAM cannot be transposed in one pass. The rows are grouped by IDVAR and
        each group is transposed and merged on its own key.
    /-------------------------------------------------------------------------------------------*/
    %put NOTE: %upcase(&_supdsn.) is the SDTMIG 3.x representation, so it is transposed before it is merged.;

    %let _dsid      = %sysfunc(open(&_supdsn.));
    %let _hasidvar  = 0;
    %let _hasqlabel = 0;

    %if %sysfunc(varnum(&_dsid., qnam)) = 0 %then %do;
        %put %str(ERR)%str(OR: QNAM is required in %upcase(&_supdsn.) but does not exist.);
        %let _err = 1;
    %end;

    %if %sysfunc(varnum(&_dsid., qval)) = 0 %then %do;
        %put %str(ERR)%str(OR: QVAL is required in %upcase(&_supdsn.) but does not exist.);
        %let _err = 1;
    %end;

    %if (%sysfunc(varnum(&_dsid., idvar)) ne 0) and (%sysfunc(varnum(&_dsid., idvarval)) ne 0) %then
        %let _hasidvar = 1;

    %if %sysfunc(varnum(&_dsid., qlabel)) ne 0 %then %let _hasqlabel = 1;

    %let _dsid = %sysfunc(close(&_dsid.));

    %if &_err. = 1 %then %return;

    data work._nsv_par;
        set &inlib..&_dom.;
    run;

    data work._nsv_sup;
        set &_supdsn.;
        where (&_suppfltr.) and qval ne ' ';
    run;

    /*-------------------------------------------------------------------------------------------/
        The keys in use, one merge per distinct IDVAR. Rows whose IDVAR is blank, and a dataset
        with no IDVAR at all, are linked by STUDYID and USUBJID alone and are taken as group 0.
    /-------------------------------------------------------------------------------------------*/
    %let _idvarlst = ;

    %if &_hasidvar. = 1 %then %do;
        proc sql noprint;
            select distinct upcase(idvar) into: _idvarlst separated by ' '
            from work._nsv_sup
            where idvar ne ' ';

            select count(*) into: _nblank
            from work._nsv_sup
            where idvar = ' ';
        quit;

        %let _nidvar = %sysfunc(countw(&_idvarlst., %str( )));
    %end;
    %else %let _nblank = 1;

    %let _from = 1;
    %if &_nblank. > 0 %then %let _from = 0;

    %do _i = &_from. %to &_nidvar.;

        %if &_i. = 0 %then %let _kv = ;
        %else %let _kv = %scan(&_idvarlst., &_i., %str( ));

        %let _txbyvars = studyid usubjid;
        %let _mgbyvars = studyid usubjid;
        %let _supwhr   = ;
        %let _vtype    = ;

        %if %length(&_kv.) ne 0 %then %do;
            %let _txbyvars = &_txbyvars. idvarval;
            %let _mgbyvars = &_mgbyvars. &_kv.;
        %end;

        %if &_hasidvar. = 1 %then %do;
            %if %length(&_kv.) = 0 %then %let _supwhr = (where=(idvar = ' '));
            %else %let _supwhr = (where=(upcase(idvar) = "&_kv."));
        %end;

        /*---------------------------------------------------------------------------------------/
            The type of the parent variable this group is linked by decides whether IDVARVAL has
            to be converted. A key which is not on the parent cannot be merged at all.
        /---------------------------------------------------------------------------------------*/
        %if %length(&_kv.) ne 0 %then %do;
            %let _dsid = %sysfunc(open(&inlib..&_dom.));
            %let _vnum = %sysfunc(varnum(&_dsid., &_kv.));

            %if &_vnum. ne 0 %then %let _vtype = %sysfunc(vartype(&_dsid., &_vnum.));

            %let _dsid = %sysfunc(close(&_dsid.));
        %end;

        %if (%length(&_kv.) ne 0) and (%length(&_vtype.) = 0) %then
            %put %str(ALE)%str(RT: %upcase(&_supdsn.) has rows with IDVAR = "&_kv." but &_kv. is not a variable of %upcase(&inlib..&_dom.), so those rows are not merged.);

        %else %do;

            proc sort data=work._nsv_sup&_supwhr. out=work._nsv_supi;
                by &_txbyvars.;
            run;

            proc transpose data=work._nsv_supi out=work._nsv_ti;
                var qval;
                id qnam;
                %if &_hasqlabel. = 1 %then %do;
                idlabel qlabel;
                %end;
                by &_txbyvars.;
            run;

            /*-----------------------------------------------------------------------------------/
                QVAL is character whatever it holds, and so is IDVARVAL, so the key is converted
                to the type of the parent variable it is merged by. The key takes its length from
                the parent, which is named first in the merge below.
            /-----------------------------------------------------------------------------------*/
            /*-----------------------------------------------------------------------------------/
                PROC TRANSPOSE writes _LABEL_ only when the transposed variable carries a label,
                so naming it in a fixed drop list warns on the runs where QVAL has none.
            /-----------------------------------------------------------------------------------*/
            %let _txdrop = _name_;
            %let _dsid   = %sysfunc(open(work._nsv_ti));

            %if %sysfunc(varnum(&_dsid., _label_)) ne 0 %then %let _txdrop = &_txdrop. _label_;

            %let _dsid = %sysfunc(close(&_dsid.));

            data work._nsv_tk;
                set work._nsv_ti(drop = &_txdrop.);
                %if &_vtype. = N %then %do;
                &_kv. = input(idvarval, best.);
                drop idvarval;
                %end;
                %else %if &_vtype. = C %then %do;
                rename idvarval = &_kv.;
                %end;
            run;

            proc sort data=work._nsv_tk;
                by &_mgbyvars.;
            run;

            proc sort data=work._nsv_par;
                by &_mgbyvars.;
            run;

            /*-----------------------------------------------------------------------------------/
                Merge this group onto the parent. A transposed row which matches no parent row
                would be dropped without a message and points at an IDVARVAL which does not
                resolve, so it is counted and written out.
            /-----------------------------------------------------------------------------------*/
            %let _norphan = 0;

            data work._nsv_par work._nsv_orph&_i.(keep = &_mgbyvars.);
                merge work._nsv_par(in=a) work._nsv_tk(in=b) end=_eof;
                by &_mgbyvars.;

                if b and not a then do;
                    _nrphn + 1;
                    output work._nsv_orph&_i.;
                end;

                if a then output work._nsv_par;

                if _eof then call symputx("_norphan", _nrphn);

                drop _nrphn _eof;
            run;

            %if %eval(&_norphan. > 0) %then
                %put %str(ALE)%str(RT: &_norphan. row(s) of %upcase(&_supdsn.) with IDVAR = "&_kv." match no row of %upcase(&inlib..&_dom.) and are not merged. Run with debug=Y and see the _nsv_orph&_i. dataset.);

        %end;

    %end;  /* IDVAR group */

    data &outdset.;
        set work._nsv_par;
    run;

%end;
%else %do;

    /*-------------------------------------------------------------------------------------------/
        The NS-- representation is horizontal and already holds one row per parent record, so it
        needs no transpose.
    /-------------------------------------------------------------------------------------------*/
    %put NOTE: %upcase(&_nsdsn.) is the SDTM 3.0 / SDTMIG 4.0 representation, so it is merged without a transpose.;

    /*-------------------------------------------------------------------------------------------/
        IDVAR names the parent variable the row is linked by, always the parent's sequence
        variable. It is read from the data rather than derived from the domain name, so that a
        split domain whose sequence variable does not carry the dataset name is linked correctly.
    /-------------------------------------------------------------------------------------------*/
    %let _dsid    = %sysfunc(open(&_nsdsn.));
    %let _hasrdom = 0;
    %let _hasidv  = 0;
    %let _hasidvn = 0;
    %let _nsdsopt = ;
    %let _keyvar  = ;

    %if %sysfunc(varnum(&_dsid., studyid)) = 0 %then %do;
        %put %str(ERR)%str(OR: STUDYID is required in %upcase(&_nsdsn.) but does not exist.);
        %let _err = 1;
    %end;

    %if %sysfunc(varnum(&_dsid., usubjid)) = 0 %then %do;
        %put %str(ERR)%str(OR: USUBJID is required in %upcase(&_nsdsn.) but does not exist.);
        %let _err = 1;
    %end;

    %do _i = 1 %to %sysfunc(countw(&nsvvars., %str( )));
        %if %sysfunc(varnum(&_dsid., %scan(&nsvvars., &_i., %str( )))) = 0 %then %do;
            %put %str(ERR)%str(OR: %upcase(%scan(&nsvvars., &_i., %str( ))) is named in NSVVARS but is not a variable of %upcase(&_nsdsn.).);
            %let _err = 1;
        %end;
    %end;

    %if %sysfunc(varnum(&_dsid., rdomain))  ne 0 %then %let _hasrdom = 1;
    %if %sysfunc(varnum(&_dsid., idvar))    ne 0 %then %let _hasidv  = 1;
    %if %sysfunc(varnum(&_dsid., idvarvln)) ne 0 %then %let _hasidvn = 1;

    %let _dsid = %sysfunc(close(&_dsid.));

    %if &_err. = 1 %then %return;

    %if (&_hasidv. = 1) and (&_hasidvn. = 1) %then %do;
        proc sql noprint;
            select distinct upcase(idvar) into: _keyvar separated by ' '
            from &_nsdsn.
            where idvar ne ' ';
        quit;
    %end;

    %let _nidvar = %sysfunc(countw(&_keyvar., %str( )));

    %if %eval(&_nidvar. > 1) %then %do;
        %put %str(ERR)%str(OR: %upcase(&_nsdsn.) holds more than one IDVAR value (&_keyvar.), so its rows are not linked to the parent by one key. %upcase(&outdset.) is not created.);
        %return;
    %end;

    %if &_nidvar. = 0 %then %do;
        %let _keyvar = ;
        %put NOTE: IDVAR on %upcase(&_nsdsn.) is null, so the rows are linked by STUDYID and USUBJID alone.;
    %end;
    %else %do;
        %let _dsid = %sysfunc(open(&inlib..&_dom.));
        %let _vnum = %sysfunc(varnum(&_dsid., &_keyvar.));
        %let _dsid = %sysfunc(close(&_dsid.));

        %if &_vnum. = 0 %then %do;
            %put %str(ERR)%str(OR: IDVAR on %upcase(&_nsdsn.) names &_keyvar. but that variable is not on %upcase(&inlib..&_dom.). %upcase(&outdset.) is not created.);
            %return;
        %end;

    %end;

    /*-------------------------------------------------------------------------------------------/
        Linkage metadata is not analysis data, so it is left behind. IDVARVLN is numeric in this
        representation, so where it carries a key it is renamed onto the parent's sequence
        variable rather than converted, and where IDVAR resolved to nothing it is dropped with
        the rest of the metadata. KEEP and DROP are applied before RENAME, so the list has to
        name it under IDVARVLN.
    /-------------------------------------------------------------------------------------------*/
    %if %length(&nsvvars.) = 0 %then %do;
        %if &_hasrdom. = 1 %then %let _nsdsopt = &_nsdsopt. rdomain;
        %if &_hasidv.  = 1 %then %let _nsdsopt = &_nsdsopt. idvar;

        %if (&_hasidvn. = 1) and (%length(&_keyvar.) = 0) %then
            %let _nsdsopt = &_nsdsopt. idvarvln;

        %if %length(&_nsdsopt.) ne 0 %then %let _nsdsopt = drop = &_nsdsopt.;
    %end;
    %else %do;
        %let _nsdsopt = keep = studyid usubjid &nsvvars.;

        %if %length(&_keyvar.) ne 0 %then %let _nsdsopt = &_nsdsopt. idvarvln;
    %end;

    %if %length(&_keyvar.) ne 0 %then
        %let _nsdsopt = &_nsdsopt. rename = (idvarvln = &_keyvar.);

    %if %length(&_nsdsopt.) ne 0 %then %let _nsdsopt = (&_nsdsopt.);

    %let _mgbyvars = studyid usubjid &_keyvar.;
    %let _lastkey  = %scan(&_mgbyvars., -1, %str( ));

    proc sort data=&inlib..&_dom. out=work._nsv_par;
        by &_mgbyvars.;
    run;

    proc sort data=&_nsdsn.&_nsdsopt. out=work._nsv_ns;
        by &_mgbyvars.;
    run;

    /*-------------------------------------------------------------------------------------------/
        Merge the non-standard variables onto the parent. The parent is named first so that it is
        its lengths, not the NS-- dataset's, that the shared key variables keep.

        The linkage is one to one by definition, and the two ways it can be broken are checked in
        this same pass so that the data is not read again.

          1. An NS-- row which matches no parent row would be dropped without a message, and
             points at an IDVARVLN which does not resolve. Those keys go to _nsv_orphan.
          2. A key which is not unique would repeat the parent row once per NS-- row.
    /-------------------------------------------------------------------------------------------*/
    %let _norphan = 0;
    %let _ndupkey = 0;

    data &outdset. work._nsv_orphan(keep = &_mgbyvars.);
        merge work._nsv_par(in=a) work._nsv_ns(in=b) end=_eof;
        by &_mgbyvars.;

        if b and not a then do;
            _nrphn + 1;
            output work._nsv_orphan;
        end;

        if not (first.&_lastkey. and last.&_lastkey.) then _ndup + 1;

        if a then output &outdset.;

        if _eof then do;
            call symputx("_norphan", _nrphn);
            call symputx("_ndupkey", _ndup);
        end;

        drop _nrphn _ndup _eof;
    run;

    %if %eval(&_norphan. > 0) %then
        %put %str(ALE)%str(RT: &_norphan. row(s) of %upcase(&_nsdsn.) match no row of %upcase(&inlib..&_dom.) and are not merged. Run with debug=Y and see the _nsv_orphan dataset.);

    %if %eval(&_ndupkey. > 0) %then
        %put %str(ALE)%str(RT: &_ndupkey. record(s) are not unique on the key %upcase(&_mgbyvars.), so %upcase(&_nsdsn.) is not merged one to one onto %upcase(&inlib..&_dom.).);

%end;

/*-----------------------------------------------------------------------------------------------/
    Delete this macro's intermediate datasets. Only the _nsv_ prefix is deleted, so an output
    dataset of any name is left alone.
/-----------------------------------------------------------------------------------------------*/
%if %substr(%upcase(&debug.), 1, 1) = N %then %do;
    proc datasets library=work nolist nowarn;
        delete _nsv_:;
    quit;
%end;

%mend merge_nsv;
