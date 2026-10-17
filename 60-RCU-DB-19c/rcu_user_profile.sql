-- =============================================================================
-- rcu_user_profile.sql - DB profile for the FMW repository (RCU) schemas
--
-- Usage (connected as SYSDBA, in the PDB that holds the RCU schemas):
--   @rcu_user_profile.sql <profile> <prefixes|->
--     <profile>   profile name, e.g. RCU_USER
--     <prefixes>  RCU schema prefix(es), comma-separated without blanks
--                 (e.g. DEV or DEV,TEST): assign the profile to every schema
--                 of these prefixes listed in SYSTEM.SCHEMA_VERSION_REGISTRY$
--                 (exact match on MRC_NAME - DEV does not hit DEV2)
--                 "-" = only create/align the profile (DB preparation before RCU)
--
-- Why: RCU creates its schemas with profile DEFAULT (19c: PASSWORD_LIFE_TIME
-- 180, FAILED_LOGIN_ATTEMPTS 10). After 180 days the data sources and the OPSS
-- bootstrap can no longer log in - the domain does not start; a data source
-- with a wrong password locks the schema after 10 attempts.
-- See 80-FMW-Architecture/rcu_middleware_architecture.md section 6.1.
--
-- Idempotent: creates the profile or aligns the two limits; other limits are
-- inherited from DEFAULT. RCU has no option to set a profile - assign it after
-- every RCU -createRepository (09-Install/07-oracle_setup_repository.sh does).
-- Called by: 60-RCU-DB-19c/07b-db_rcu_profile.sh, 09-Install/07-oracle_setup_repository.sh
-- =============================================================================
SET SERVEROUTPUT ON FEEDBACK OFF VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
DEFINE rcu_profile = '&1'
DEFINE rcu_prefix  = '&2'

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_profiles WHERE profile = UPPER('&rcu_profile');
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE PROFILE "' || UPPER('&rcu_profile') || '" LIMIT'
            || ' PASSWORD_LIFE_TIME UNLIMITED FAILED_LOGIN_ATTEMPTS UNLIMITED';
        DBMS_OUTPUT.PUT_LINE('IHW:OK:profile ' || UPPER('&rcu_profile') || ' created');
    ELSE
        EXECUTE IMMEDIATE 'ALTER PROFILE "' || UPPER('&rcu_profile') || '" LIMIT'
            || ' PASSWORD_LIFE_TIME UNLIMITED FAILED_LOGIN_ATTEMPTS UNLIMITED';
        DBMS_OUTPUT.PUT_LINE('IHW:OK:profile ' || UPPER('&rcu_profile') || ' exists - limits aligned');
    END IF;
END;
/

DECLARE
    v_reg NUMBER;
    v_n   NUMBER := 0;
BEGIN
    IF '&rcu_prefix' = '-' THEN
        RETURN;
    END IF;
    SELECT COUNT(*) INTO v_reg FROM dba_tables
     WHERE owner = 'SYSTEM' AND table_name = 'SCHEMA_VERSION_REGISTRY$';
    IF v_reg = 0 THEN
        DBMS_OUTPUT.PUT_LINE('IHW:FAIL:SYSTEM.SCHEMA_VERSION_REGISTRY$ not found - no RCU repository in this DB');
        RETURN;
    END IF;
    FOR r IN (SELECT u.username, u.profile
                FROM dba_users u
               WHERE u.username IN (SELECT owner FROM system.schema_version_registry$
                                     WHERE INSTR(',' || UPPER('&rcu_prefix') || ',',
                                                 ',' || mrc_name || ',') > 0)
               ORDER BY u.username) LOOP
        IF r.profile <> UPPER('&rcu_profile') THEN
            EXECUTE IMMEDIATE 'ALTER USER "' || r.username || '" PROFILE "' || UPPER('&rcu_profile') || '"';
            DBMS_OUTPUT.PUT_LINE('IHW:OK:' || r.username || ' profile ' || r.profile || ' -> ' || UPPER('&rcu_profile'));
        ELSE
            DBMS_OUTPUT.PUT_LINE('IHW:OK:' || r.username || ' already has profile ' || UPPER('&rcu_profile'));
        END IF;
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('IHW:WARN:no schemas with prefix(es) &rcu_prefix in the registry');
    END IF;
END;
/

-- Result: limits of the profile and state of the schemas
SET PAGESIZE 100 LINESIZE 160 FEEDBACK OFF
COLUMN resource_name FORMAT A24
COLUMN limit         FORMAT A12
COLUMN username      FORMAT A20
COLUMN profile       FORMAT A12
COLUMN account_status FORMAT A16
SELECT resource_name, limit FROM dba_profiles
 WHERE profile = UPPER('&rcu_profile')
   AND resource_name IN ('PASSWORD_LIFE_TIME','FAILED_LOGIN_ATTEMPTS');
SELECT username, profile, account_status, TO_CHAR(expiry_date,'YYYY-MM-DD') expiry
  FROM dba_users
 WHERE username IN (SELECT owner FROM system.schema_version_registry$
                     WHERE INSTR(',' || UPPER('&rcu_prefix') || ',', ',' || mrc_name || ',') > 0)
 ORDER BY username;
