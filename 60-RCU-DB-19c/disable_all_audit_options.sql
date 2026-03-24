-- =============================================================================
-- disable_all_audit_options.sql
-- Deaktiviert alle klassischen Statement- und Privilege-Audit-Optionen.
-- Ausführen als: SYS oder DBA-User
-- Verwendung  : @disable_all_audit_options.sql
-- Quelle      : Gunther Pipperr | https://pipperr.de
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE

  CURSOR c_stmt_audit IS
    SELECT user_name, audit_option
      FROM DBA_STMT_AUDIT_OPTS;

  CURSOR c_priv_audit IS
    SELECT user_name, privilege
      FROM DBA_PRIV_AUDIT_OPTS;

  v_sql          VARCHAR2(1000);
  v_user_clause  VARCHAR2(100);
  v_count_stmt   PLS_INTEGER := 0;
  v_count_priv   PLS_INTEGER := 0;
  v_count_err    PLS_INTEGER := 0;

BEGIN

  DBMS_OUTPUT.PUT_LINE('=== DISABLE STATEMENT AUDIT OPTIONS ===');

  <<STMT_AUDIT_OPTIONS>>
  FOR r_stmt IN c_stmt_audit LOOP

    IF r_stmt.user_name IS NULL THEN
      v_user_clause := '';
    ELSE
      v_user_clause := ' BY ' || DBMS_ASSERT.ENQUOTE_NAME(r_stmt.user_name, FALSE);
    END IF;

    v_sql := 'NOAUDIT ' || r_stmt.audit_option || v_user_clause;

    BEGIN
      EXECUTE IMMEDIATE v_sql;
      v_count_stmt := v_count_stmt + 1;
      DBMS_OUTPUT.PUT_LINE('  OK : ' || v_sql);
    EXCEPTION
      WHEN OTHERS THEN
        v_count_err := v_count_err + 1;
        DBMS_OUTPUT.PUT_LINE('  ERR: ' || v_sql);
        DBMS_OUTPUT.PUT_LINE('       ' || SQLERRM);
    END;

  END LOOP STMT_AUDIT_OPTIONS;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== DISABLE PRIVILEGE AUDIT OPTIONS ===');

  <<PRIV_AUDIT_OPTIONS>>
  FOR r_priv IN c_priv_audit LOOP

    IF r_priv.user_name IS NULL THEN
      v_user_clause := '';
    ELSE
      v_user_clause := ' BY ' || DBMS_ASSERT.ENQUOTE_NAME(r_priv.user_name, FALSE);
    END IF;

    v_sql := 'NOAUDIT ' || r_priv.privilege || v_user_clause;

    BEGIN
      EXECUTE IMMEDIATE v_sql;
      v_count_priv := v_count_priv + 1;
      DBMS_OUTPUT.PUT_LINE('  OK : ' || v_sql);
    EXCEPTION
      WHEN OTHERS THEN
        v_count_err := v_count_err + 1;
        DBMS_OUTPUT.PUT_LINE('  ERR: ' || v_sql);
        DBMS_OUTPUT.PUT_LINE('       ' || SQLERRM);
    END;

  END LOOP PRIV_AUDIT_OPTIONS;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== SUMMARY ===');
  DBMS_OUTPUT.PUT_LINE('  Statement options disabled : ' || v_count_stmt);
  DBMS_OUTPUT.PUT_LINE('  Privilege options disabled : ' || v_count_priv);
  DBMS_OUTPUT.PUT_LINE('  Errors                     : ' || v_count_err);

END;
/
