-- =============================================================================
-- generate_unified_audit_policy.sql
-- Generiert ein CREATE AUDIT POLICY Statement aus den aktuell aktiven
-- klassischen Audit-Optionen (DBA_STMT_AUDIT_OPTS / DBA_PRIV_AUDIT_OPTS).
-- Das Ergebnis als Ausgangsbasis für viper_audit_policies.sql verwenden.
-- Ausführen als: SYS oder DBA-User
-- Verwendung  : @generate_unified_audit_policy.sql
-- Quelle      : Gunther Pipperr | https://pipperr.de
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE

  CURSOR c_stmt_audit IS
    SELECT DISTINCT audit_option
      FROM DBA_STMT_AUDIT_OPTS
     ORDER BY audit_option;

  CURSOR c_priv_audit IS
    SELECT DISTINCT privilege
      FROM DBA_PRIV_AUDIT_OPTS
     ORDER BY privilege;

  TYPE t_varchar_tab IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;

  v_stmt_options  t_varchar_tab;
  v_priv_options  t_varchar_tab;

  v_policy_name   VARCHAR2(30)   := 'MIGRATED_AUDIT_POLICY';
  v_clob          CLOB           := EMPTY_CLOB();
  v_idx           PLS_INTEGER;
  v_stmt_count    PLS_INTEGER    := 0;
  v_priv_count    PLS_INTEGER    := 0;

  PROCEDURE append_line(p_text IN VARCHAR2) IS
  BEGIN
    v_clob := v_clob || p_text || CHR(10);
  END append_line;

BEGIN

  <<COLLECT_STMT>>
  FOR r_stmt IN c_stmt_audit LOOP
    v_stmt_count := v_stmt_count + 1;
    v_stmt_options(v_stmt_count) := r_stmt.audit_option;
  END LOOP COLLECT_STMT;

  <<COLLECT_PRIV>>
  FOR r_priv IN c_priv_audit LOOP
    v_priv_count := v_priv_count + 1;
    v_priv_options(v_priv_count) := r_priv.privilege;
  END LOOP COLLECT_PRIV;

  append_line('-- ---------------------------------------------------------------------------');
  append_line('-- Generated : ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  append_line('-- Source    : DBA_STMT_AUDIT_OPTS / DBA_PRIV_AUDIT_OPTS');
  append_line('-- Statement options : ' || v_stmt_count);
  append_line('-- Privilege options : ' || v_priv_count);
  append_line('-- ---------------------------------------------------------------------------');
  append_line('');

  IF v_stmt_count = 0 AND v_priv_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('INFO: Keine Audit-Optionen gefunden – nichts zu generieren.');
    RETURN;
  END IF;

  append_line('CREATE AUDIT POLICY ' || v_policy_name);

  IF v_stmt_count > 0 THEN
    append_line('  ACTIONS');
    v_idx := 1;
    <<BUILD_STMT_ACTIONS>>
    WHILE v_idx <= v_stmt_count LOOP
      IF v_idx < v_stmt_count OR v_priv_count > 0 THEN
        append_line('    ' || v_stmt_options(v_idx) || ',');
      ELSE
        append_line('    ' || v_stmt_options(v_idx));
      END IF;
      v_idx := v_idx + 1;
    END LOOP BUILD_STMT_ACTIONS;
  END IF;

  IF v_priv_count > 0 THEN
    append_line('  PRIVILEGES');
    v_idx := 1;
    <<BUILD_PRIV_ACTIONS>>
    WHILE v_idx <= v_priv_count LOOP
      IF v_idx < v_priv_count THEN
        append_line('    ' || v_priv_options(v_idx) || ',');
      ELSE
        append_line('    ' || v_priv_options(v_idx));
      END IF;
      v_idx := v_idx + 1;
    END LOOP BUILD_PRIV_ACTIONS;
  END IF;

  append_line(';');
  append_line('');
  append_line('-- Policy für alle User aktivieren:');
  append_line('AUDIT POLICY ' || v_policy_name || ';');
  append_line('');
  append_line('-- Optional: nur für bestimmte User:');
  append_line('-- AUDIT POLICY ' || v_policy_name || ' BY SCOTT, HR;');

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== GENERATED UNIFIED AUDIT POLICY ===');
  DBMS_OUTPUT.PUT_LINE('');

  -- CLOB zeilenweise ausgeben
  DECLARE
    v_offset  PLS_INTEGER := 1;
    v_len     PLS_INTEGER;
    v_char    VARCHAR2(1);
    v_out     VARCHAR2(4000) := '';
  BEGIN
    v_len := DBMS_LOB.GETLENGTH(v_clob);
    WHILE v_offset <= v_len LOOP
      v_char := DBMS_LOB.SUBSTR(v_clob, 1, v_offset);
      IF v_char = CHR(10) THEN
        DBMS_OUTPUT.PUT_LINE(v_out);
        v_out := '';
      ELSE
        v_out := v_out || v_char;
      END IF;
      v_offset := v_offset + 1;
    END LOOP;
    IF v_out IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE(v_out);
    END IF;
  END;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== SUMMARY ===');
  DBMS_OUTPUT.PUT_LINE('  Statement actions : ' || v_stmt_count);
  DBMS_OUTPUT.PUT_LINE('  Privilege actions : ' || v_priv_count);

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
    RAISE;
END;
/
