-- plsql-reconciliation: the data
--
-- Generates a ledger and an inward file that between them hit every status,
-- including the awkward ones. The numbers are deterministic, not random, so
-- the assertion script compares two runs over identical data.
--
-- Change &&rows to make the timing script interesting. 200000 is roughly a
-- night's inward volume for a mid-sized clearing member.

DEFINE rows = 200000

SET SERVEROUTPUT ON

TRUNCATE TABLE recon_result;
TRUNCATE TABLE recon_result_err;
TRUNCATE TABLE ledger_entry;
TRUNCATE TABLE recon_staging;

-- The ledger. One entry per cheque. Every fortieth one is already cleared,
-- which is the case that has to be caught rather than matched again.
INSERT /*+ APPEND */ INTO ledger_entry
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
-- problems that turn up in a real file.
INSERT /*+ APPEND */ INTO recon_staging
    (batch_id, line_no, cheque_no, account_no, ifsc, amount, issue_date)
SELECT 1,
       l.ledger_id,
       l.cheque_no,
       l.account_no,
       l.ifsc,
       -- every 97th line is presented for the wrong amount
       CASE WHEN MOD(l.ledger_id, 97) = 0 THEN l.amount + 0.01 ELSE l.amount END,
       DATE '2026-06-20'
  FROM ledger_entry l
 WHERE MOD(l.ledger_id, 313) <> 0;        -- every 313th cheque is not in the file at all

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

DECLARE
    v_ledger  NUMBER;
    v_file    NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_ledger FROM ledger_entry;
    SELECT COUNT(*) INTO v_file   FROM recon_staging WHERE batch_id = 1;
    DBMS_OUTPUT.PUT_LINE('ledger  ' || v_ledger || ' entries');
    DBMS_OUTPUT.PUT_LINE('file    ' || v_file   || ' lines');
END;
/
