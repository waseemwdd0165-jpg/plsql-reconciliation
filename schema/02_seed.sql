-- plsql-reconciliation: the data
--
-- Generates a ledger and an inward file that between them hit every status,
-- including the awkward ones. The numbers are deterministic, not random, so
-- the assertion script compares two runs over identical data.
--
-- The caller decides how many rows: run_all.sql asks for 200000, roughly a
-- night's inward volume for a mid-sized clearing member, and test/ci.sql asks
-- for fewer so a build does not sit waiting on the row-by-row loop.

SET SERVEROUTPUT ON

TRUNCATE TABLE recon_result;
TRUNCATE TABLE recon_result_err;
TRUNCATE TABLE ledger_entry;
TRUNCATE TABLE recon_staging;

-- The ledger. One entry per cheque. Every fortieth one is already cleared,
-- which is the case that has to be caught rather than matched again.
INSERT INTO ledger_entry
    (ledger_id, ifsc, account_no, cheque_no, amount, cleared_flag, cleared_on)
SELECT level,
       'HDFC000' || LPAD(MOD(level, 900) + 100, 4, '0'),
       LPAD(MOD(level * 7919, 900000000) + 100000000, 12, '0'),
       LPAD(MOD(level, 900000) + 100000, 6, '0'),
       ROUND(1000 + MOD(level * 131, 500000) / 100, 2),
       CASE WHEN MOD(level, 40) = 0 THEN 'Y' ELSE 'N' END,
       CASE WHEN MOD(level, 40) = 0 THEN DATE '2026-06-15' END
  FROM dual
CONNECT BY level <= &&rows;

COMMIT;

-- The inward file for batch 1. It is the ledger, minus a slice, plus the
-- problems that turn up in a real file: every 97th line is presented for the
-- wrong amount, and every 313th cheque is not in the file at all.
--
-- Keep the comments out here. A comment on its own line inside the statement
-- got SQL*Plus to run it as an insert of no rows, silently, and the first sign
-- of it was the equivalence assertion complaining three scripts later that the
-- seed had never produced an AMOUNT_MISMATCH.
INSERT INTO recon_staging
    (batch_id, line_no, cheque_no, account_no, ifsc, amount, issue_date)
SELECT 1,
       l.ledger_id,
       l.cheque_no,
       l.account_no,
       l.ifsc,
       CASE WHEN MOD(l.ledger_id, 97) = 0 THEN l.amount + 0.01 ELSE l.amount END,
       DATE '2026-06-20'
  FROM ledger_entry l
 WHERE MOD(l.ledger_id, 313) <> 0;

-- Cheques the file presents that the ledger has never heard of.
INSERT INTO recon_staging (batch_id, line_no, cheque_no, account_no, ifsc, amount, issue_date)
SELECT 1,
       1000000 + level,
       LPAD(level, 6, '0'),
       '999900000000',
       'HDFC0009999',
       500.00,
       DATE '2026-06-20'
  FROM dual
CONNECT BY level <= 200;

-- The same cheque presented twice in one file. The second presentation is the
-- duplicate, whichever order the rows come back in.
INSERT INTO recon_staging (batch_id, line_no, cheque_no, account_no, ifsc, amount, issue_date)
SELECT 1,
       2000000 + l.ledger_id,
       l.cheque_no,
       l.account_no,
       l.ifsc,
       l.amount,
       DATE '2026-06-20'
  FROM ledger_entry l
 WHERE MOD(l.ledger_id, 1009) = 0
   AND MOD(l.ledger_id, 313) <> 0;

-- Rows the ETL could not fill in. These must not stop the run.
INSERT INTO recon_staging (batch_id, line_no, cheque_no, account_no, ifsc, amount, issue_date)
SELECT 1, 3000000 + level, NULL, '123456789012', 'HDFC0001234', 100.00, DATE '2026-06-20'
  FROM dual CONNECT BY level <= 25;

INSERT INTO recon_staging (batch_id, line_no, cheque_no, account_no, ifsc, amount, issue_date)
SELECT 1, 3100000 + level, '123456', '123456789012', 'HDFC0001234', NULL, DATE '2026-06-20'
  FROM dual CONNECT BY level <= 25;

COMMIT;

BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'LEDGER_ENTRY');
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'RECON_STAGING');
END;
/

-- Say what was built, broken down, so a seed that quietly loses a slice shows
-- up here rather than three scripts later as a mystery.
DECLARE
    -- Variables first: PL/SQL will not accept a declaration after a nested
    -- subprogram.
    v_n NUMBER;

    PROCEDURE say(p_label IN VARCHAR2, p_count IN NUMBER) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(RPAD(p_label, 34) || LPAD(p_count, 8));
    END;
BEGIN
    SELECT COUNT(*) INTO v_n FROM ledger_entry;
    say('ledger entries', v_n);

    SELECT COUNT(*) INTO v_n FROM recon_staging WHERE batch_id = 1;
    say('file lines, total', v_n);

    SELECT COUNT(*) INTO v_n FROM recon_staging WHERE batch_id = 1 AND line_no < 1000000;
    say('  presented from the ledger', v_n);

    SELECT COUNT(*) INTO v_n FROM recon_staging
     WHERE batch_id = 1 AND line_no BETWEEN 1000000 AND 1999999;
    say('  not in the ledger at all', v_n);

    SELECT COUNT(*) INTO v_n FROM recon_staging
     WHERE batch_id = 1 AND line_no BETWEEN 2000000 AND 2999999;
    say('  presented a second time', v_n);

    SELECT COUNT(*) INTO v_n FROM recon_staging WHERE batch_id = 1 AND line_no >= 3000000;
    say('  incomplete rows', v_n);

    SELECT COUNT(*) INTO v_n FROM recon_staging s
     WHERE s.batch_id = 1 AND MOD(s.line_no, 97) = 0 AND s.line_no < 1000000;
    say('  of those, wrong amount', v_n);
END;
/
