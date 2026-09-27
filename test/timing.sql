-- plsql-reconciliation: what the rewrite actually bought
--
-- Times both procedures three times each and reports the median, because one
-- run of anything on a shared database measures the neighbours as much as the
-- code. Run assert_equivalent.sql first: a faster answer that is not the same
-- answer is not worth timing.

SET SERVEROUTPUT ON
SET FEEDBACK OFF

DECLARE
    TYPE t_ms IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    l_loop    t_ms;
    l_set     t_ms;
    l_start   NUMBER;
    v_batch   CONSTANT NUMBER := 1;
    c_runs    CONSTANT PLS_INTEGER := 3;

    FUNCTION median(p IN t_ms) RETURN NUMBER IS
        TYPE t_sorted IS TABLE OF NUMBER;
        l t_sorted := t_sorted();
        x NUMBER;
    BEGIN
        FOR i IN 1 .. p.COUNT LOOP
            l.EXTEND; l(i) := p(i);
        END LOOP;
        FOR i IN 1 .. l.COUNT LOOP                     -- three elements; a sort is overkill
            FOR j IN i + 1 .. l.COUNT LOOP
                IF l(j) < l(i) THEN
                    x := l(i); l(i) := l(j); l(j) := x;
                END IF;
            END LOOP;
        END LOOP;
        RETURN l(TRUNC(l.COUNT / 2) + 1);
    END median;
BEGIN
    FOR i IN 1 .. c_runs LOOP
        l_start := DBMS_UTILITY.GET_TIME;
        pkg_recon.run_row_by_row(v_batch);
        l_loop(i) := (DBMS_UTILITY.GET_TIME - l_start) * 10;     -- centiseconds to ms

        l_start := DBMS_UTILITY.GET_TIME;
        pkg_recon.run_set_based(v_batch);
        l_set(i) := (DBMS_UTILITY.GET_TIME - l_start) * 10;

        DBMS_OUTPUT.PUT_LINE('run ' || i
            || '   row by row ' || LPAD(l_loop(i), 8) || ' ms'
            || '   set based ' || LPAD(l_set(i), 8) || ' ms');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('median  row by row ' || median(l_loop) || ' ms');
    DBMS_OUTPUT.PUT_LINE('median  set based  ' || median(l_set)  || ' ms');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Fill these into the README from your own run. Do not quote'
        || ' somebody else''s numbers, including mine.');
END;
/

SET FEEDBACK ON
