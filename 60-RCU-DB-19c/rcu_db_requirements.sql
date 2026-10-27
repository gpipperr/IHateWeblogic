-- =============================================================================
-- rcu_db_requirements.sql - FMW 14.1.2 database requirements for RCU (read-only)
--
-- Usage (connected as SYSDBA / DBA, in the PDB that holds / will hold the
-- RCU schemas):
--   @rcu_db_requirements.sql
--
-- One line per value, evaluated by rcu_db_req_eval (00-Setup/IHateWeblogic_lib.sh):
--   IHW:REQ|VERSION|<version_full>
--   IHW:REQ|EDITION|<banner>
--   IHW:REQ|CHARSET|<NLS_CHARACTERSET>       IHW:REQ|NCHARSET|<NLS_NCHAR_CHARACTERSET>
--   IHW:REQ|JAVAVM|<status of JAVAVM in dba_registry or MISSING>
--   IHW:REQ|PARAM|<name>|<value>             processes, open_cursors, ...
--   IHW:REQ|OPTION|<v$option parameter>|<TRUE/FALSE>
-- Requirements: 80-FMW-Architecture/rcu_middleware_architecture.md section 9
-- Used by: 60-RCU-DB-19c/05-db_create_database.sh,
--          09-Install/07-oracle_setup_repository.sh, 07-Maintenance/rcu_repository_check.sh
-- =============================================================================
SET SERVEROUTPUT ON FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 300

DECLARE
    v_val VARCHAR2(400);
BEGIN
    SELECT version_full INTO v_val FROM v$instance;
    DBMS_OUTPUT.PUT_LINE('IHW:REQ|VERSION|' || v_val);
    SELECT banner INTO v_val FROM v$version WHERE ROWNUM = 1;
    DBMS_OUTPUT.PUT_LINE('IHW:REQ|EDITION|' || v_val);
    FOR r IN (SELECT parameter, value FROM nls_database_parameters
               WHERE parameter IN ('NLS_CHARACTERSET', 'NLS_NCHAR_CHARACTERSET')) LOOP
        DBMS_OUTPUT.PUT_LINE('IHW:REQ|'
            || CASE r.parameter WHEN 'NLS_CHARACTERSET' THEN 'CHARSET' ELSE 'NCHARSET' END
            || '|' || r.value);
    END LOOP;
    BEGIN
        SELECT status INTO v_val FROM dba_registry WHERE comp_id = 'JAVAVM';
    EXCEPTION WHEN NO_DATA_FOUND THEN v_val := 'MISSING';
    END;
    DBMS_OUTPUT.PUT_LINE('IHW:REQ|JAVAVM|' || v_val);
    FOR r IN (SELECT name, value FROM v$parameter
               WHERE name IN ('processes', 'open_cursors', 'session_cached_cursors', 'db_files',
                              'db_block_size', 'shared_pool_size', 'sga_max_size', 'sga_target')
               ORDER BY name) LOOP
        DBMS_OUTPUT.PUT_LINE('IHW:REQ|PARAM|' || r.name || '|' || r.value);
    END LOOP;
    FOR r IN (SELECT parameter, value FROM v$option
               WHERE parameter IN ('Fine-grained access control', 'Partitioning')) LOOP
        DBMS_OUTPUT.PUT_LINE('IHW:REQ|OPTION|' || r.parameter || '|' || r.value);
    END LOOP;
END;
/
