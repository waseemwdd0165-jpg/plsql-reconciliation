-- What continuous integration runs.
--
-- The same scripts run_all.sql runs, over a smaller ledger so a build does not
-- sit waiting on the row-by-row loop, and with the session set to abandon the
-- run on the first Oracle error rather than carry on and report success.
--
-- Run it from the repository root, because the paths below are relative to
-- the working directory rather than to this file:
--
--   sqlplus -S -L user/password@host/service @test/ci.sql
--
-- Twenty thousand rows is still enough for the seed to produce all six
-- verdicts, which assert_equivalent.sql insists on before it will pass.

WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE

SET ECHO OFF
-- Leave feedback on: 'N rows created' after each statement is how a seed
-- that silently inserts nothing gets noticed.
SET FEEDBACK ON
SET LINESIZE 200
SET PAGESIZE 100
SET SERVEROUTPUT ON SIZE UNLIMITED

DEFINE rows = 20000

PROMPT
PROMPT == schema ==============================================================
@schema/01_tables.sql

PROMPT
PROMPT == data ================================================================
@schema/02_seed.sql

PROMPT
PROMPT == package =============================================================
@src/pkg_recon.pks
@src/pkg_recon.pkb

-- CREATE PACKAGE succeeds even when the body does not compile: SQL*Plus prints
-- a warning and carries on. A build that only checks for SQL errors would call
-- that a pass, so ask the data dictionary instead.
DECLARE
    v_errors PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_errors FROM user_errors WHERE name = 'PKG_RECON';
    IF v_errors > 0 THEN
        FOR e IN (SELECT type, line, position, text
                    FROM user_errors
                   WHERE name = 'PKG_RECON'
                   ORDER BY type, sequence)
        LOOP
            DBMS_OUTPUT.PUT_LINE(e.type || ' ' || e.line || ':' || e.position
                                 || '  ' || e.text);
        END LOOP;
        RAISE_APPLICATION_ERROR(-20099, 'pkg_recon did not compile cleanly');
    END IF;
    DBMS_OUTPUT.PUT_LINE('pkg_recon compiled with no errors');
END;
/

PROMPT
PROMPT == are the two runs the same? ==========================================
@test/assert_equivalent.sql

PROMPT
PROMPT == does the timing harness run? ========================================
PROMPT (the numbers below are from a shared build machine over a small ledger,
PROMPT  so they say nothing useful about either version. Run it yourself.)
@test/timing.sql

PROMPT
PROMPT done.
EXIT SUCCESS
