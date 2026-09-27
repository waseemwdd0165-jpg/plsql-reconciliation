-- plsql-reconciliation: does the rewrite agree with the original?
--
-- Runs both procedures over the same batch and fails loudly on the first
-- disagreement. This is the only reason it is safe to delete the loop: not
-- that the new one is faster, but that on this data it decides every line the
-- same way, down to the wording of the detail and the ledger id it attaches.
--
-- Run 01_tables.sql, 02_seed.sql and the package first.

SET SERVEROUTPUT ON
SET FEEDBACK OFF

DECLARE
    v_rows       PLS_INTEGER;
    v_diff       PLS_INTEGER;
    v_errors     PLS_INTEGER;
    v_batch      CONSTANT NUMBER := 1;

    PROCEDURE say(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_text);
    END;
BEGIN
    pkg_recon.run_row_by_row(v_batch);
    pkg_recon.run_set_based(v_batch);

    -- Nothing should have been diverted. If it was, the rewrite is not
    -- equivalent, it is quietly dropping rows.
    SELECT COUNT(*) INTO v_errors FROM recon_result_err;
    IF v_errors > 0 THEN
        RAISE_APPLICATION_ERROR(-20001,
            v_errors || ' row(s) went to the error log; the set based run is not clean');
    END IF;

    -- Same number of lines decided.
    SELECT COUNT(*) INTO v_rows
      FROM recon_result WHERE batch_id = v_batch AND run_tag = pkg_recon.c_row_by_row;
    SELECT COUNT(*) INTO v_diff
      FROM recon_result WHERE batch_id = v_batch AND run_tag = pkg_recon.c_set_based;
    IF v_rows <> v_diff THEN
        RAISE_APPLICATION_ERROR(-20002,
            'row by row wrote ' || v_rows || ' lines, set based wrote ' || v_diff);
    END IF;

    -- Same decision on every line. The symmetric difference of the two sets
    -- has to be empty, so a line that differs in status, in wording, or in
    -- the ledger id it points at, shows up here.
    -- The brackets are not decoration: MINUS and UNION ALL have the same
    -- precedence and Oracle applies them left to right, so without them this
    -- asks a different and much weaker question.
    SELECT COUNT(*) INTO v_diff FROM (
        (
            SELECT line_no, status, detail, ledger_id
              FROM recon_result WHERE batch_id = v_batch AND run_tag = pkg_recon.c_row_by_row
            MINUS
            SELECT line_no, status, detail, ledger_id
              FROM recon_result WHERE batch_id = v_batch AND run_tag = pkg_recon.c_set_based
        )
        UNION ALL
        (
            SELECT line_no, status, detail, ledger_id
              FROM recon_result WHERE batch_id = v_batch AND run_tag = pkg_recon.c_set_based
            MINUS
            SELECT line_no, status, detail, ledger_id
              FROM recon_result WHERE batch_id = v_batch AND run_tag = pkg_recon.c_row_by_row
        )
    );

    IF v_diff > 0 THEN
        say('the two runs disagree on ' || v_diff || ' line(s); first ten:');
        FOR r IN (
            SELECT a.line_no, a.status AS loop_status, b.status AS set_status,
                   a.detail AS loop_detail, b.detail AS set_detail
              FROM recon_result a
              JOIN recon_result b
                ON b.batch_id = a.batch_id AND b.line_no = a.line_no
               AND b.run_tag = pkg_recon.c_set_based
             WHERE a.batch_id = v_batch
               AND a.run_tag = pkg_recon.c_row_by_row
               AND (a.status <> b.status
                    OR NVL(a.detail, '~') <> NVL(b.detail, '~')
                    OR NVL(a.ledger_id, -1) <> NVL(b.ledger_id, -1))
             ORDER BY a.line_no
             FETCH FIRST 10 ROWS ONLY)
        LOOP
            say('  line ' || r.line_no || '  loop=' || r.loop_status
                || '  set=' || r.set_status);
            say('        loop detail: ' || r.loop_detail);
            say('        set  detail: ' || r.set_detail);
        END LOOP;
        RAISE_APPLICATION_ERROR(-20003, 'the rewrite is not equivalent');
    END IF;

    say('both runs decided ' || v_rows || ' lines identically');
    say('');
    say('  status               lines');
    FOR r IN (
        SELECT status, COUNT(*) AS lines
          FROM recon_result
         WHERE batch_id = v_batch AND run_tag = pkg_recon.c_set_based
         GROUP BY status
         ORDER BY status)
    LOOP
        say('  ' || RPAD(r.status, 20) || LPAD(r.lines, 7));
    END LOOP;

    -- Every status has to be exercised, or the assertion proved nothing about
    -- the branches it never reached.
    FOR r IN (
        SELECT column_value AS status FROM TABLE(sys.odcivarchar2list(
            'MATCHED', 'AMOUNT_MISMATCH', 'NOT_IN_LEDGER',
            'ALREADY_CLEARED', 'DUPLICATE_IN_FILE', 'INCOMPLETE_ROW')))
    LOOP
        SELECT COUNT(*) INTO v_diff
          FROM recon_result
         WHERE batch_id = v_batch AND run_tag = pkg_recon.c_set_based
           AND status = r.status;
        IF v_diff = 0 THEN
            RAISE_APPLICATION_ERROR(-20004,
                'the seed data never produced ' || r.status
                || ', so that branch is untested');
        END IF;
    END LOOP;

    say('');
    say('every status was exercised');
END;
/

SET FEEDBACK ON
