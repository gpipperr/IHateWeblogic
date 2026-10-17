-- =============================================================================
-- rcu_registry_overview.sql - all RCU prefixes of this database (read-only)
--
-- Usage (connected as SYSDBA / DBA, in the PDB that holds the RCU schemas):
--   @rcu_registry_overview.sql
--
-- One line per prefix (MRC_NAME) of SYSTEM.SCHEMA_VERSION_REGISTRY$:
--   IHW:PREFIX|<prefix>|<schemas>|<missing users>|<profiles>|<status>|<earliest expiry>|<EBR>
--   <EBR> = EDITIONS_ENABLED of the schemas: Y (RCU database type EBR),
--           N (type ORACLE), Y,N (mixed - should not happen)
--   <missing users> = registry rows whose database user no longer exists
--                     (orphaned entries, e.g. users dropped without RCU)
-- or IHW:NOREG when the registry table does not exist.
-- First line: IHW:SECUREFILE|<db_securefile> - with FORCE the FIRST RCU run in
-- a database fails: the registry (CLOB column BACKUP) is created in the
-- non-ASSM tablespace SYSTEM -> ORA-43853 (rcu_middleware_architecture.md 4.2)
-- Used by: 60-RCU-DB-19c/07b-db_rcu_profile.sh, 09-Install/07-oracle_setup_repository.sh
-- =============================================================================
SET SERVEROUTPUT ON FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 300

DECLARE
    v_reg NUMBER;
    v_sf  VARCHAR2(30);
BEGIN
    SELECT value INTO v_sf FROM v$parameter WHERE name = 'db_securefile';
    DBMS_OUTPUT.PUT_LINE('IHW:SECUREFILE|' || UPPER(v_sf));
    SELECT COUNT(*) INTO v_reg FROM dba_tables
     WHERE owner = 'SYSTEM' AND table_name = 'SCHEMA_VERSION_REGISTRY$';
    IF v_reg = 0 THEN
        DBMS_OUTPUT.PUT_LINE('IHW:NOREG');
        RETURN;
    END IF;
    FOR r IN (
        SELECT 'IHW:PREFIX|' || x.mrc_name
               || '|' || x.schemas
               || '|' || x.missing
               || '|' || NVL(x.profiles, '-')
               || '|' || NVL(x.status, '-')
               || '|' || NVL(TO_CHAR(x.min_expiry, 'YYYY-MM-DD'), '-')
               || '|' || NVL(x.ebr, '-') AS line
          FROM (SELECT g.mrc_name,
                       COUNT(*) schemas,
                       SUM(CASE WHEN u.username IS NULL THEN 1 ELSE 0 END) missing,
                       LISTAGG(DISTINCT u.profile, ',') WITHIN GROUP (ORDER BY u.profile) profiles,
                       LISTAGG(DISTINCT u.account_status, ',') WITHIN GROUP (ORDER BY u.account_status) status,
                       MIN(u.expiry_date) min_expiry,
                       LISTAGG(DISTINCT u.editions_enabled, ',') WITHIN GROUP (ORDER BY u.editions_enabled DESC) ebr
                  FROM system.schema_version_registry$ g
                  LEFT JOIN dba_users u ON u.username = g.owner
                 GROUP BY g.mrc_name) x
         ORDER BY x.mrc_name) LOOP
        DBMS_OUTPUT.PUT_LINE(r.line);
    END LOOP;
END;
/
