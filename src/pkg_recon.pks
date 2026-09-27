CREATE OR REPLACE PACKAGE pkg_recon AS
    /*
     * Reconciles an inward clearing batch against the ledger, twice over.
     *
     * run_row_by_row  the shape the original was in: a cursor, a lookup per
     *                 row, and a commit every so often inside the loop
     * run_set_based   the rewrite: one statement, one transaction
     *
     * Both write into RECON_RESULT tagged with which one wrote them, so that
     * test/assert_equivalent.sql can prove they agree before anybody trusts
     * the faster one. A rewrite nobody can check is not a rewrite, it is a
     * second implementation of the same rules that will drift.
     *
     * The status precedence is the contract, and it is the same in both:
     *
     *   1  INCOMPLETE_ROW      a key column or the amount is missing
     *   2  DUPLICATE_IN_FILE   this cheque appeared earlier in the same file
     *   3  NOT_IN_LEDGER       the ledger has never heard of it
     *   4  ALREADY_CLEARED     the ledger already cleared it
     *   5  AMOUNT_MISMATCH     presented for a different amount
     *   6  MATCHED
     */

    c_row_by_row CONSTANT VARCHAR2(30) := 'ROW_BY_ROW';
    c_set_based  CONSTANT VARCHAR2(30) := 'SET_BASED';

    PROCEDURE run_row_by_row(p_batch_id IN NUMBER, p_commit_every IN PLS_INTEGER DEFAULT 1000);

    PROCEDURE run_set_based(p_batch_id IN NUMBER);

END pkg_recon;
/
