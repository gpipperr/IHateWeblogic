-- =============================================================================
-- fmw_rcu_audit_policies.sql
-- FMW/RCU Sicherheits-Audit-Policies für Oracle 19c CDB.
-- Ausführen als: SYS (CDB$ROOT) – common policies (CONTAINER = ALL), in
--               CDB$ROOT aktiviert = wirksam in allen Containern (auch der PDB
--               mit den RCU-Schemas). Bis 2026-11-02 ohne CONTAINER = ALL:
--               nur Root-lokal, in der PDB "ORA-46357 not found" (verschluckt).
-- Verwendung  : @fmw_rcu_audit_policies.sql
-- Vorlage     : gpiconsult_audit_policies.sql
-- Quelle      : Gunther Pipperr | https://pipperr.de
-- =============================================================================

-- =============================================================================
-- Policy 1: FMW_RCU_DB_MIN_SEC_AUDIT
-- Überwacht privilegierte DDL-Operationen und kritische Systemänderungen.
-- =============================================================================

-- erneuter Lauf: eine aktivierte Policy lässt sich nicht löschen -> erst NOAUDIT
BEGIN
    BEGIN EXECUTE IMMEDIATE 'NOAUDIT POLICY FMW_RCU_DB_MIN_SEC_AUDIT'; EXCEPTION WHEN OTHERS THEN NULL; END;
    EXECUTE IMMEDIATE 'DROP AUDIT POLICY FMW_RCU_DB_MIN_SEC_AUDIT';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE AUDIT POLICY FMW_RCU_DB_MIN_SEC_AUDIT
  privileges
    CREATE external job,
    CREATE job,
    CREATE any job
  actions
    -- User / Role / Profile Management
    CREATE USER,    ALTER USER,    DROP USER,
    CREATE ROLE,    ALTER ROLE,    DROP ROLE,
    CREATE profile, ALTER profile, DROP profile,
    -- Synonyms (ALTER SYNONYM does not exist in 19c)
    CREATE synonym, DROP synonym,
    -- Database Links (ALTER DATABASE LINK does not exist in 19c)
    CREATE DATABASE link, DROP DATABASE link,
    -- Code Objects (ALTER PROCEDURE / ALTER TRIGGER not auditable as actions)
    CREATE PROCEDURE, DROP PROCEDURE,
    CREATE TRIGGER,   DROP TRIGGER,
    -- Table DDL
    CREATE TABLE, ALTER TABLE, DROP TABLE,
    -- rename
    RENAME,
    -- Grants / Revokes
    GRANT,
    REVOKE,
    -- System / Database
    ALTER system,
    ALTER DATABASE,
    -- Tablespace
    CREATE tablespace,
    DROP tablespace,
    -- Directory
    CREATE directory,
    DROP directory,
    -- Audit Trail Protection (Object-specific actions)
    DELETE   ON audsys.aud$unified,
    UPDATE   ON audsys.aud$unified,
    -- Session
    logon,
    logoff
  CONTAINER = ALL;

-- =============================================================================
-- Policy 2: FMW_RCU_SEC_AUDIT_TRUNC
-- Überwacht TRUNCATE auf der Unified Audit Tabelle (Manipulationsschutz).
-- =============================================================================

-- erneuter Lauf: eine aktivierte Policy lässt sich nicht löschen -> erst NOAUDIT
BEGIN
    BEGIN EXECUTE IMMEDIATE 'NOAUDIT POLICY FMW_RCU_SEC_AUDIT_TRUNC'; EXCEPTION WHEN OTHERS THEN NULL; END;
    EXECUTE IMMEDIATE 'DROP AUDIT POLICY FMW_RCU_SEC_AUDIT_TRUNC';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE AUDIT POLICY FMW_RCU_SEC_AUDIT_TRUNC
  ACTIONS TRUNCATE TABLE
    WHEN 'SYS_CONTEXT(''USERENV'', ''CURRENT_SCHEMA'') = ''AUDSYS''
     AND SYS_CONTEXT(''USERENV'', ''CURRENT_OBJECT'') = ''AUD$UNIFIED'''
  EVALUATE PER STATEMENT
  CONTAINER = ALL;

-- =============================================================================
-- Policies aktivieren (alle Container)
-- =============================================================================

-- Aktivierung in CDB$ROOT: common policy -> gilt in allen Containern.
AUDIT POLICY FMW_RCU_DB_MIN_SEC_AUDIT;
AUDIT POLICY FMW_RCU_SEC_AUDIT_TRUNC;

-- =============================================================================
-- Prüfen ob Policies aktiv sind
-- =============================================================================

COL POLICY_NAME    FORMAT A35
COL ENABLED_OPTION FORMAT A15
COL ENTITY_NAME    FORMAT A20
COL ENTITY_TYPE    FORMAT A20
COL SUCCESS        FORMAT A8
COL FAILURE        FORMAT A8
SELECT POLICY_NAME
     , ENABLED_OPTION
     , ENTITY_NAME
     , ENTITY_TYPE
     , SUCCESS
     , FAILURE
  FROM audit_unified_enabled_policies
 WHERE POLICY_NAME IN ('FMW_RCU_DB_MIN_SEC_AUDIT', 'FMW_RCU_SEC_AUDIT_TRUNC')
 ORDER BY POLICY_NAME;

COL COMMON FORMAT A6
SELECT DISTINCT POLICY_NAME, COMMON
  FROM audit_unified_policies
 WHERE POLICY_NAME IN ('FMW_RCU_DB_MIN_SEC_AUDIT', 'FMW_RCU_SEC_AUDIT_TRUNC');
