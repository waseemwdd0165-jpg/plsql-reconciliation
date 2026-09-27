CREATE OR REPLACE PACKAGE BODY pkg_recon AS

    ----------------------------------------------------------------------
    -- The original shape.
    --
    -- It is kept here on purpose. Nobody can judge the rewrite without the
    -- thing it replaced, and the faults are worth naming rather than quietly
    -- deleting:
    --
    --   * one SELECT per line, so 200,000 lines is 200,000 round trips
    --     through the SQL engine, each one a context switch out of PL/SQL
    --   * a COMMIT inside the loop, so a failure halfway leaves the batch
    --     half reconciled and a re-run double counts unless somebody
    --     remembers to clear it out first
    --   * duplicate detection through an associative array, which is correct
    --     only because the cursor happens to be ordered; the dependency is
    --     invisible from the code that relies on it
    --   * a WHEN OTHERS that would let a genuinely broken row pass as
    --     reconciled, which is the worst of the four
    ----------------------------------------------------------------------
    PROCEDURE run_row_by_row(p_batch_id IN NUMBER, p_commit_every IN PLS_INTEGER DEFAULT 1000)
    IS
        CURSOR c_file IS
            SELECT batch_id, line_no, cheque_no, account_no, ifsc, amount
              FROM recon_staging
             WHERE batch_id = p_batch_id
             ORDER BY line_no;                  -- the duplicate rule leans on this

        TYPE t_seen IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(40);
        l_seen        t_seen;
        l_key         VARCHAR2(40);
        l_status      recon_result.status%TYPE;
        l_detail      recon_result.detail%TYPE;
        l_ledger_id   ledger_entry.ledger_id%TYPE;
        l_ledger_amt  ledger_entry.amount%TYPE;
        l_cleared     ledger_entry.cleared_flag%TYPE;
        l_done        PLS_INTEGER := 0;
    BEGIN
        DELETE FROM recon_result
         WHERE batch_id = p_batch_id AND run_tag = c_row_by_row;

        FOR r IN c_file LOOP
            l_status    := NULL;
            l_detail    := NULL;
            l_ledger_id := NULL;

            IF r.cheque_no IS NULL OR r.account_no IS NULL
               OR r.ifsc IS NULL OR r.amount IS NULL THEN
                l_status := 'INCOMPLETE_ROW';
                l_detail := 'a key column or the amount is missing';
            ELSE
                l_key := r.ifsc || '|' || r.account_no || '|' || r.cheque_no;

                IF l_seen.EXISTS(l_key) THEN
                    l_status := 'DUPLICATE_IN_FILE';
                    l_detail := 'same cheque as line ' || l_seen(l_key);
                ELSE
                    l_seen(l_key) := r.line_no;

                    BEGIN
                        SELECT ledger_id, amount, cleared_flag
                          INTO l_ledger_id, l_ledger_amt, l_cleared
                          FROM ledger_entry
                         WHERE ifsc = r.ifsc
                           AND account_no = r.account_no
                           AND cheque_no = r.cheque_no;

                        IF l_cleared = 'Y' THEN
                            l_status := 'ALREADY_CLEARED';
                            l_detail := 'the ledger cleared this cheque already';
                        ELSIF l_ledger_amt <> r.amount THEN
                            l_status := 'AMOUNT_MISMATCH';
                            l_detail := 'presented ' || TO_CHAR(r.amount, 'FM999999990.00')
                                        || ', ledger holds ' || TO_CHAR(l_ledger_amt, 'FM999999990.00');
                        ELSE
                            l_status := 'MATCHED';
                        END IF;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            l_status    := 'NOT_IN_LEDGER';
                            l_detail    := 'no ledger entry for this cheque';
                            l_ledger_id := NULL;
                    END;
                END IF;
            END IF;

            INSERT INTO recon_result (batch_id, line_no, run_tag, status, detail, ledger_id)
            VALUES (r.batch_id, r.line_no, c_row_by_row, l_status, l_detail, l_ledger_id);

            l_done := l_done + 1;
            IF MOD(l_done, p_commit_every) = 0 THEN
                COMMIT;                          -- the line this rewrite exists to delete
            END IF;
        END LOOP;

        COMMIT;
    END run_row_by_row;

    ----------------------------------------------------------------------
    -- The rewrite.
    --
    -- One statement. The per-row lookup becomes an outer join the optimiser
    -- can hash, the associative array becomes ROW_NUMBER, and the commit
    -- moves outside, so the batch is either reconciled or it is not.
    --
    -- LOG ERRORS keeps the last property the loop had and the plain INSERT
    -- would otherwise lose: a row the database cannot accept goes to
    -- RECON_RESULT_ERR and the other 199,999 still land.
    ----------------------------------------------------------------------
    PROCEDURE run_set_based(p_batch_id IN NUMBER)
    IS
    BEGIN
        DELETE FROM recon_result
         WHERE batch_id = p_batch_id AND run_tag = c_set_based;

        INSERT INTO recon_result (batch_id, line_no, run_tag, status, detail, ledger_id)
        SELECT s.batch_id,
               s.line_no,
               c_set_based,
               CASE
                   WHEN s.cheque_no IS NULL OR s.account_no IS NULL
                        OR s.ifsc IS NULL OR s.amount IS NULL      THEN 'INCOMPLETE_ROW'
                   WHEN s.presentation > 1                         THEN 'DUPLICATE_IN_FILE'
                   WHEN l.ledger_id IS NULL                        THEN 'NOT_IN_LEDGER'
                   WHEN l.cleared_flag = 'Y'                       THEN 'ALREADY_CLEARED'
                   WHEN l.amount <> s.amount                       THEN 'AMOUNT_MISMATCH'
                   ELSE                                                 'MATCHED'
               END,
               CASE
                   WHEN s.cheque_no IS NULL OR s.account_no IS NULL
                        OR s.ifsc IS NULL OR s.amount IS NULL      THEN
                       'a key column or the amount is missing'
                   WHEN s.presentation > 1                         THEN
                       'same cheque as line ' || s.first_line
                   WHEN l.ledger_id IS NULL                        THEN
                       'no ledger entry for this cheque'
                   WHEN l.cleared_flag = 'Y'                       THEN
                       'the ledger cleared this cheque already'
                   WHEN l.amount <> s.amount                       THEN
                       'presented ' || TO_CHAR(s.amount, 'FM999999990.00')
                       || ', ledger holds ' || TO_CHAR(l.amount, 'FM999999990.00')
               END,
               CASE
                   WHEN s.cheque_no IS NULL OR s.account_no IS NULL
                        OR s.ifsc IS NULL OR s.amount IS NULL      THEN NULL
                   WHEN s.presentation > 1                         THEN NULL
                   ELSE l.ledger_id
               END
          FROM (
                SELECT k.batch_id,
                       k.line_no,
                       k.cheque_no,
                       k.account_no,
                       k.ifsc,
                       k.amount,
                       -- The ordering the loop relied on, written down. An
                       -- incomplete row has no identity, so it is nobody's
                       -- first presentation and nobody's duplicate: its
                       -- partition key is null and the CASE holds it at 1.
                       CASE
                           WHEN k.identity IS NULL THEN 1
                           ELSE ROW_NUMBER() OVER (PARTITION BY k.identity
                                                       ORDER BY k.line_no)
                       END AS presentation,
                       MIN(k.line_no) OVER (PARTITION BY k.identity) AS first_line
                  FROM (
                        SELECT st.batch_id,
                               st.line_no,
                               st.cheque_no,
                               st.account_no,
                               st.ifsc,
                               st.amount,
                               CASE
                                   WHEN st.cheque_no  IS NOT NULL
                                    AND st.account_no IS NOT NULL
                                    AND st.ifsc       IS NOT NULL
                                    AND st.amount     IS NOT NULL
                                   THEN st.ifsc || '|' || st.account_no || '|' || st.cheque_no
                               END AS identity
                          FROM recon_staging st
                         WHERE st.batch_id = p_batch_id
                       ) k
               ) s
          LEFT JOIN ledger_entry l
                 ON l.ifsc       = s.ifsc
                AND l.account_no = s.account_no
                AND l.cheque_no  = s.cheque_no
          LOG ERRORS INTO recon_result_err ('batch ' || p_batch_id) REJECT LIMIT UNLIMITED;

        COMMIT;
    END run_set_based;

END pkg_recon;
/
