-- plsql-reconciliation: the tables
--
-- Three tables and an error log. RECON_STAGING is what the ETL lands the
-- inward clearing file into. LEDGER_ENTRY is the core banking side. Both
-- reconciliation procedures write into RECON_RESULT, and the point of the
-- repository is that they write exactly the same thing.

-- Idempotent, so this runs on an empty database as happily as on one that
-- already holds a previous run. A bare DROP of a table that is not there
-- raises ORA-00942 and takes the whole script down with it.
BEGIN
    FOR t IN (SELECT table_name
                FROM user_tables
               WHERE table_name IN ('RECON_RESULT_ERR', 'RECON_RESULT',
                                    'LEDGER_ENTRY', 'RECON_STAGING'))
    LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name
                          || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

CREATE TABLE recon_staging (
    batch_id     NUMBER(10)    NOT NULL,
    line_no      NUMBER(10)    NOT NULL,
    cheque_no    VARCHAR2(6),
    account_no   VARCHAR2(18),
    ifsc         VARCHAR2(11),
    amount       NUMBER(15,2),
    issue_date   DATE,
    CONSTRAINT pk_recon_staging PRIMARY KEY (batch_id, line_no)
);

COMMENT ON TABLE recon_staging IS
    'One row per line of the inward file. Nullable on purpose: the file is
     external and a column can arrive empty, and the reconciliation has to say
     so rather than fail.';

CREATE TABLE ledger_entry (
    ledger_id    NUMBER(12)    NOT NULL,
    ifsc         VARCHAR2(11)  NOT NULL,
    account_no   VARCHAR2(18)  NOT NULL,
    cheque_no    VARCHAR2(6)   NOT NULL,
    amount       NUMBER(15,2)  NOT NULL,
    cleared_flag CHAR(1)       DEFAULT 'N' NOT NULL,
    cleared_on   DATE,
    CONSTRAINT pk_ledger_entry PRIMARY KEY (ledger_id),
    CONSTRAINT ck_ledger_cleared CHECK (cleared_flag IN ('Y', 'N'))
);

-- A cheque is identified by branch, account and number together. The index
-- carries the same three columns in the same order as the join, so the
-- set-based statement can hash or range scan rather than probe per row.
CREATE UNIQUE INDEX ux_ledger_cheque
    ON ledger_entry (ifsc, account_no, cheque_no);

CREATE TABLE recon_result (
    batch_id     NUMBER(10)    NOT NULL,
    line_no      NUMBER(10)    NOT NULL,
    run_tag      VARCHAR2(30)  NOT NULL,
    status       VARCHAR2(24)  NOT NULL,
    detail       VARCHAR2(200),
    ledger_id    NUMBER(12),
    CONSTRAINT pk_recon_result PRIMARY KEY (batch_id, line_no, run_tag),
    CONSTRAINT ck_recon_status CHECK (status IN (
        'MATCHED',
        'AMOUNT_MISMATCH',
        'NOT_IN_LEDGER',
        'ALREADY_CLEARED',
        'DUPLICATE_IN_FILE',
        'INCOMPLETE_ROW'))
);

COMMENT ON COLUMN recon_result.run_tag IS
    'Which procedure wrote the row: ROW_BY_ROW or SET_BASED. Both write into
     the same table so the assertion script can diff them with one query.';

-- The error log the set-based statement diverts bad rows into, so that one
-- unusable row costs that row rather than the run.
BEGIN
    DBMS_ERRLOG.CREATE_ERROR_LOG(
        dml_table_name      => 'RECON_RESULT',
        err_log_table_name  => 'RECON_RESULT_ERR');
END;
/
