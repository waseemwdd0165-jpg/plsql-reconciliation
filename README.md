# plsql-reconciliation

[![run against Oracle](https://github.com/waseemwdd0165-jpg/plsql-reconciliation/actions/workflows/ci.yml/badge.svg)](https://github.com/waseemwdd0165-jpg/plsql-reconciliation/actions/workflows/ci.yml)

A nightly clearing reconciliation written twice: the row-by-row loop it used to
be, and the set-based statement it became, with a script that proves the two
decide every line the same way.

```
sqlplus user/password@db @run_all.sql
```

## What is checked, and what is not

Every push starts an Oracle Database Free container, builds the schema, seeds
it, compiles the package and runs the equivalence assertion. So the badge above
answers the questions that matter: does this compile, and do the two
reconciliations decide every line identically. It would go red the moment they
did not.

There are still **no timings in this README**, and that is deliberate. A number
measured on a shared build machine over a small ledger says nothing about your
database. `test/timing.sql` prints its own and tells you to fill in yours.

CI runs the same scripts as `run_all.sql` over 20,000 rows rather than 200,000,
which is small enough to keep a build short and still large enough for the seed
to produce all six verdicts. The assertion refuses to pass unless it does.

## The job

An inward clearing file is landed in `RECON_STAGING`, one row per line. Each
line is matched against `LEDGER_ENTRY` and gets one of six verdicts, in this
order of precedence:

| | Status | |
|---|---|---|
| 1 | `INCOMPLETE_ROW` | a key column or the amount is missing |
| 2 | `DUPLICATE_IN_FILE` | this cheque appeared earlier in the same file |
| 3 | `NOT_IN_LEDGER` | the ledger has never heard of it |
| 4 | `ALREADY_CLEARED` | the ledger cleared it already |
| 5 | `AMOUNT_MISMATCH` | presented for a different amount |
| 6 | `MATCHED` | |

A cheque is identified by IFSC, account and number together, never by number
alone.

## What was wrong with the loop

`pkg_recon.run_row_by_row` is kept in the repository deliberately. A rewrite
cannot be judged without the thing it replaced, and the faults are worth naming
rather than quietly deleting:

- **One `SELECT` per line.** Two hundred thousand lines is two hundred thousand
  context switches out of PL/SQL and back.
- **A `COMMIT` inside the loop.** This is the one that costs money rather than
  time. A failure halfway leaves the batch half reconciled, and a re-run
  double-counts unless somebody remembers to clear the partial results first.
  The set-based version is one transaction: the batch is reconciled or it is
  not.
- **Duplicate detection through an associative array.** It is correct only
  because the cursor happens to carry `ORDER BY line_no`. Nothing in the code
  that depends on that ordering mentions it. In the rewrite it is a
  `ROW_NUMBER() OVER (PARTITION BY identity ORDER BY line_no)`, where the
  dependency is the code.

## What the rewrite does

One `INSERT ... SELECT`. The per-row lookup becomes an outer join the optimiser
can hash; the array becomes an analytic function; the commit moves outside.

`LOG ERRORS INTO recon_result_err ... REJECT LIMIT UNLIMITED` keeps the one
property the loop had that a plain `INSERT` would have lost: a row the database
cannot accept goes to the error log and the other 199,999 still land.

One subtlety the equivalence turns on. An incomplete row has no identity, so it
must not sit in any cheque's partition, or a real row that follows it would be
numbered second and reported as a duplicate. The inner query computes the
identity as `NULL` for incomplete rows and partitions on that, which keeps them
out of everybody else's window.

## Proving they agree

`test/assert_equivalent.sql` runs both over the same batch and fails on the
first disagreement. This is the only reason it is safe to delete the loop: not
that the new one is faster, but that it decides the same thing. It checks:

- nothing was diverted to the error log
- both wrote the same number of lines
- the symmetric difference of the two result sets is empty, over status,
  detail wording **and** the ledger id each one attached
- every one of the six statuses actually occurred, so no branch went untested

That last check is the one people leave out. An equivalence test over data that
never produces `ALREADY_CLEARED` has not tested `ALREADY_CLEARED`.

The seed builds a ledger and a file that hits all six: every 313th cheque
withheld, every 97th presented one paisa out, every 40th already cleared in the
ledger, 200 cheques the ledger has never seen, a slice presented twice, and
fifty rows the ETL could not fill in.

CI also refuses a package that compiles with warnings. `CREATE PACKAGE BODY`
succeeds even when the body is broken, so a build that only watches for SQL
errors would call that a pass; `test/ci.sql` asks `user_errors` instead.

## Layout

```
run_all.sql                  everything, in order
schema/01_tables.sql         four tables and the error log
schema/02_seed.sql           200,000 entries and a file with every problem in it
src/pkg_recon.pks/.pkb       both procedures, same contract
test/assert_equivalent.sql   the two runs must decide identically
test/timing.sql              three runs each, median reported
test/ci.sql                  what the build runs, on a smaller ledger
.github/workflows/ci.yml     starts Oracle in a container and runs it
```

Needs Oracle 12c or later: `FETCH FIRST`, and `DBMS_ERRLOG` for the error log
table.
