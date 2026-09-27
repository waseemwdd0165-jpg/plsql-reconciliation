-- plsql-reconciliation: everything, in order.
--
--   sqlplus user/password@db @run_all.sql
--
-- Needs a schema you can create and drop tables in. Nothing here touches
-- anything outside the four tables it creates.

SET ECHO OFF
SET LINESIZE 200
SET PAGESIZE 100
WHENEVER SQLERROR EXIT SQL.SQLCODE

PROMPT
PROMPT == schema ==============================================================
@@schema/01_tables.sql

PROMPT
PROMPT == data ================================================================
@@schema/02_seed.sql

PROMPT
PROMPT == package =============================================================
@@src/pkg_recon.pks
@@src/pkg_recon.pkb

SHOW ERRORS PACKAGE pkg_recon
SHOW ERRORS PACKAGE BODY pkg_recon

PROMPT
PROMPT == are the two runs the same? ==========================================
@@test/assert_equivalent.sql

PROMPT
PROMPT == how much faster? ====================================================
@@test/timing.sql

PROMPT
PROMPT done.
