-- =============================================================================
-- Script   : apex_user_profile.sql
-- Purpose  : DB profile for the APEX / ORDS runtime accounts – no password
--            expiry, no lock-out. An expired or locked ORDS_PUBLIC_USER stops
--            every APEX page and REST call (same rule as the profile RCU_USER,
--            60-RCU-DB-19c/rcu_user_profile.sql).
-- Call     : @apex_user_profile.sql <PROFILE> <-|assign>
--              -       create / align the profile only
--              assign  also assign it to the existing runtime accounts
--                      ORDS_PUBLIC_USER, APEX_PUBLIC_USER,
--                      APEX_REST_PUBLIC_USER, APEX_PUBLIC_ROUTER
-- Runs as  : SYS (or a DBA) in the PDB of APEX / ORDS
-- Used by  : 12-APEX-Ords/01-prepare-database.sh, 02-install-apex.sh,
--            04-install-ords.sh (idempotent – run as often as needed)
-- Output   : IHW:OK|WARN|FAIL:<text> lines (parsed by the scripts)
-- Risk     : FAILED_LOGIN_ATTEMPTS UNLIMITED = no lock-out – the passwords are
--            long and random (ORDS wallet / apex_sec.conf.des3) and the DB
--            listener must be reachable from the application hosts only.
-- Author   : Gunther Pipperr | https://pipperr.de
-- License  : Apache 2.0
-- =============================================================================
SET SERVEROUTPUT ON FEEDBACK OFF VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE apex_profile = '&1'
DEFINE apex_mode    = '&2'

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_profiles WHERE profile = UPPER('&apex_profile');
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE PROFILE "' || UPPER('&apex_profile') || '" LIMIT'
            || ' PASSWORD_LIFE_TIME UNLIMITED FAILED_LOGIN_ATTEMPTS UNLIMITED';
        DBMS_OUTPUT.PUT_LINE('IHW:OK:profile ' || UPPER('&apex_profile') || ' created');
    ELSE
        EXECUTE IMMEDIATE 'ALTER PROFILE "' || UPPER('&apex_profile') || '" LIMIT'
            || ' PASSWORD_LIFE_TIME UNLIMITED FAILED_LOGIN_ATTEMPTS UNLIMITED';
        DBMS_OUTPUT.PUT_LINE('IHW:OK:profile ' || UPPER('&apex_profile') || ' exists - limits aligned');
    END IF;
END;
/

DECLARE
    v_n NUMBER := 0;
BEGIN
    IF '&apex_mode' <> 'assign' THEN
        RETURN;
    END IF;
    FOR r IN (SELECT username, profile
                FROM dba_users
               WHERE username IN ('ORDS_PUBLIC_USER', 'APEX_PUBLIC_USER',
                                  'APEX_REST_PUBLIC_USER', 'APEX_PUBLIC_ROUTER')
               ORDER BY username) LOOP
        IF r.profile <> UPPER('&apex_profile') THEN
            EXECUTE IMMEDIATE 'ALTER USER "' || r.username || '" PROFILE "' || UPPER('&apex_profile') || '"';
            DBMS_OUTPUT.PUT_LINE('IHW:OK:' || r.username || ' profile ' || r.profile || ' -> ' || UPPER('&apex_profile'));
        ELSE
            DBMS_OUTPUT.PUT_LINE('IHW:OK:' || r.username || ' already has profile ' || UPPER('&apex_profile'));
        END IF;
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('IHW:OK:no APEX / ORDS runtime account yet - profile only');
    END IF;
END;
/
