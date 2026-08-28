-- O2C Migration: Snowflake Hybrid Table schema with index build waits
-- Co-authored with CoCo
-- ============================================================
-- Cash Clear — Snowflake Schema
-- master    → standard tables (SAP replica, read-only ETL)
-- cashapp   → HYBRID tables (transactional, OLTP workload)
-- cashapp_authdb → HYBRID tables (auth, OLTP workload)
-- ============================================================


CREATE WAREHOUSE IF NOT EXISTS O2C_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

USE WAREHOUSE O2C_WH;

CREATE DATABASE IF NOT EXISTS O2C_DB;
USE DATABASE O2C_DB;
CREATE SCHEMA IF NOT EXISTS master;
CREATE SCHEMA IF NOT EXISTS cashapp;
CREATE SCHEMA IF NOT EXISTS cashapp_authdb;


-- ============================================================
-- MASTER SCHEMA — Standard Tables (SAP replica, read-only)
-- No changes. Normal Snowflake tables for analytical reads.
-- ============================================================

USE SCHEMA master;

CREATE TABLE IF NOT EXISTS master."AVIK" (
    "AVSID"            VARCHAR(15) NOT NULL,
    "AVART"            VARCHAR(3)  NOT NULL,
    "BUKRS"            VARCHAR(4)  NOT NULL,
    "KTONR"            VARCHAR(10) NOT NULL,
    "BUDAT"            DATE        NOT NULL,
    "WAERS"            VARCHAR(3)  NOT NULL,
    "AVSUM"            INTEGER     NOT NULL,
    "SC_SOURCE"        VARCHAR(5)  NOT NULL,
    "INBOUND_MSG_TYPE" VARCHAR(30) NOT NULL,
    CONSTRAINT "AVIK_pkey" PRIMARY KEY ("AVSID")
);

CREATE TABLE IF NOT EXISTS master."AVIP" (
    "AVSID"       VARCHAR(15)  NOT NULL,
    "AVPID"       VARCHAR(3)   NOT NULL,
    "BELNR_REF"   INTEGER      NOT NULL,
    "ITEM_AMOUNT" INTEGER      NOT NULL,
    "REASON_CODE" VARCHAR(15)  NULL,
    "NOTES"       VARCHAR(255) NOT NULL,
    "SC_SOURCE"   VARCHAR(5)   NOT NULL,
    CONSTRAINT "AVIP_pkey" PRIMARY KEY ("AVSID", "AVPID")
);

CREATE TABLE IF NOT EXISTS master."BKPF" (
    "Source_Step" VARCHAR(8)  NOT NULL,
    "BUKRS"       VARCHAR(4)  NOT NULL,
    "BELNR"       INTEGER     NOT NULL,
    "GJAHR"       INTEGER     NOT NULL,
    "BLART"       VARCHAR(2)  NOT NULL,
    "BLDAT"       DATE        NOT NULL,
    "BUDAT"       DATE        NOT NULL,
    "CPUDT"       DATE        NOT NULL,
    "WAERS"       VARCHAR(3)  NOT NULL,
    "USNAM"       VARCHAR(15) NOT NULL,
    "TCODE"       VARCHAR(4)  NOT NULL,
    "AWTYP"       VARCHAR(4)  NULL,
    "AWKEY"       VARCHAR(10) NULL,
    "XBLNR"       VARCHAR(10) NOT NULL,
    CONSTRAINT "BKPF_pkey" PRIMARY KEY ("Source_Step", "BUKRS", "BELNR")
);

CREATE TABLE IF NOT EXISTS master."BSAD" (
    "BUKRS"  VARCHAR(4)   NOT NULL,
    "KUNNR"  VARCHAR(10)  NOT NULL,
    "UMSKZ"  VARCHAR(255) NULL,
    "AUGDT"  DATE         NOT NULL,
    "AUGBL"  INTEGER      NOT NULL,
    "AUGCP"  DATE         NOT NULL,
    "GJAHR"  INTEGER      NOT NULL,
    "BELNR"  INTEGER      NOT NULL,
    "BUZEI"  VARCHAR(3)   NOT NULL,
    "BSCHL"  VARCHAR(2)   NOT NULL,
    "KOART"  VARCHAR(1)   NOT NULL,
    "SHKZG"  VARCHAR(1)   NOT NULL,
    "MWSKZ"  VARCHAR(2)   NULL,
    "DMBTR"  INTEGER      NOT NULL,
    "WRBTR"  INTEGER      NOT NULL,
    "HKONT"  INTEGER      NOT NULL,
    "ZUONR"  VARCHAR(20)  NOT NULL,
    "SGTXT"  VARCHAR(80)  NOT NULL
);

CREATE TABLE IF NOT EXISTS master."BSEG" (
    "Source_Step" VARCHAR(8)    NOT NULL,
    "BUKRS"       VARCHAR(4)    NOT NULL,
    "BELNR"       INTEGER       NOT NULL,
    "GJAHR"       INTEGER       NOT NULL,
    "BUZEI"       VARCHAR(3)    NOT NULL,
    "KOART"       VARCHAR(1)    NOT NULL,
    "BSCHL"       VARCHAR(2)    NOT NULL,
    "SHKZG"       VARCHAR(1)    NOT NULL,
    "KUNNR"       VARCHAR(10)   NULL,
    "HKONT"       INTEGER       NOT NULL,
    "WRBTR"       NUMERIC(18,2) NOT NULL,
    "DMBTR"       NUMERIC(18,2) NOT NULL,
    "WAERS"       VARCHAR(3)    NOT NULL,
    "MWSKZ"       VARCHAR(2)    NULL,
    "PSWBT"       NUMERIC(18,2) NOT NULL,
    "UMSKZ"       VARCHAR(1)    NULL,
    "AUGBL"       VARCHAR(255)  NULL,
    "AUGDT"       VARCHAR(255)  NULL,
    "AUGCP"       VARCHAR(255)  NULL,
    "ZUONR"       VARCHAR(10)   NULL,
    "SGTXT"       VARCHAR(150)  NOT NULL,
    "REBZG"       INTEGER       NULL,
    "REBZJ"       INTEGER       NULL,
    "REBZZ"       VARCHAR(3)    NULL,
    "PYORD"       VARCHAR(10)   NULL,
    CONSTRAINT "BSEG_pkey" PRIMARY KEY ("Source_Step", "BUKRS", "BELNR", "GJAHR", "BUZEI")
);

CREATE TABLE IF NOT EXISTS master."BSET" (
    "Source_Step" VARCHAR(8)    NOT NULL,
    "BUKRS"       VARCHAR(4)    NOT NULL,
    "BELNR"       INTEGER       NOT NULL,
    "GJAHR"       INTEGER       NOT NULL,
    "BUZEI"       VARCHAR(3)    NOT NULL,
    "MWSKZ"       VARCHAR(2)    NOT NULL,
    "KTOSL"       VARCHAR(3)    NOT NULL,
    "HKONT"       INTEGER       NOT NULL,
    "TXJCD"       VARCHAR(255)  NULL,
    "FWBAS"       NUMERIC(18,2) NOT NULL,
    "FWSTE"       NUMERIC(18,2) NOT NULL,
    "HWBAS"       NUMERIC(18,2) NOT NULL,
    "HWSTE"       NUMERIC(18,2) NOT NULL,
    "KBETR"       INTEGER       NOT NULL,
    CONSTRAINT "BSET_pkey" PRIMARY KEY ("Source_Step", "BUKRS", "BELNR")
);

CREATE TABLE IF NOT EXISTS master."BSID" (
    "Source_Step" VARCHAR(8)    NOT NULL,
    "BUKRS"       VARCHAR(4)    NOT NULL,
    "KUNNR"       VARCHAR(10)   NOT NULL,
    "UMSKZ"       VARCHAR(1)    NULL,
    "AUGDT"       VARCHAR(255)  NULL,
    "AUGBL"       VARCHAR(255)  NULL,
    "AUGCP"       VARCHAR(255)  NULL,
    "GJAHR"       INTEGER       NOT NULL,
    "BELNR"       INTEGER       NOT NULL,
    "BUZEI"       VARCHAR(3)    NOT NULL,
    "BSCHL"       VARCHAR(2)    NOT NULL,
    "KOART"       VARCHAR(1)    NOT NULL,
    "SHKZG"       VARCHAR(1)    NOT NULL,
    "MWSKZ"       VARCHAR(255)  NULL,
    "DMBTR"       INTEGER       NOT NULL,
    "WRBTR"       NUMERIC(18,2) NOT NULL,
    "PSWSL"       VARCHAR(3)    NOT NULL,
    "ZFBDT"       DATE          NOT NULL,
    "ZTERM"       VARCHAR(5)    NOT NULL,
    "HKONT"       INTEGER       NOT NULL,
    "ZUONR"       VARCHAR(15)   NOT NULL,
    "SGTXT"       VARCHAR(150)  NOT NULL,
    "REBZG"       INTEGER       NULL,
    "XBLNR"       VARCHAR(16)   NULL,
    "WAERS"       VARCHAR(5)    NULL
);

CREATE TABLE IF NOT EXISTS master."CEPC" (
    "BUKRS"       VARCHAR(4)  NOT NULL,
    "PRCTR"       VARCHAR(8)  NOT NULL,
    "Description" VARCHAR(20) NOT NULL,
    "DATAB"       DATE        NOT NULL,
    "DATBI"       DATE        NOT NULL,
    CONSTRAINT "CEPC_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."CEPCT" (
    "BUKRS"  VARCHAR(4)  NOT NULL,
    "PRCTR"  VARCHAR(8)  NOT NULL,
    "SPRAS"  VARCHAR(1)  NOT NULL,
    "TEXT1"  VARCHAR(20) NOT NULL,
    CONSTRAINT "CEPCT_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."CSKS" (
    "BUKRS"       VARCHAR(4)  NOT NULL,
    "KOSTL"       VARCHAR(8)  NOT NULL,
    "Description" VARCHAR(20) NOT NULL,
    "DATAB"       DATE        NOT NULL,
    "DATBI"       DATE        NOT NULL,
    CONSTRAINT "CSKS_pkey" PRIMARY KEY ("BUKRS", "KOSTL")
);

CREATE TABLE IF NOT EXISTS master."CSKT" (
    "BUKRS"  VARCHAR(4)  NOT NULL,
    "KOSTL"  VARCHAR(8)  NOT NULL,
    "SPRAS"  VARCHAR(1)  NOT NULL,
    "TEXT1"  VARCHAR(20) NOT NULL,
    CONSTRAINT "CSKT_pkey" PRIMARY KEY ("BUKRS", "KOSTL")
);

CREATE TABLE IF NOT EXISTS master."Dispute_Cases" (
    "Source_Step" VARCHAR(8)   NOT NULL,
    "CASE_ID"     VARCHAR(10)  NOT NULL,
    "SC"          VARCHAR(5)   NOT NULL,
    "BUKRS"       VARCHAR(4)   NOT NULL,
    "KUNNR"       VARCHAR(10)  NOT NULL,
    "AMOUNT"      INTEGER      NOT NULL,
    "WAERS"       VARCHAR(3)   NOT NULL,
    "OPENED"      DATE         NULL,
    "STATUS"      VARCHAR(4)   NOT NULL,
    "REASON_CODE" VARCHAR(30)  NULL,
    "DETAIL"      VARCHAR(150) NULL,
    "REASON"      VARCHAR(80)  NULL,
    CONSTRAINT "Dispute_Cases_pkey" PRIMARY KEY ("Source_Step", "CASE_ID")
);

CREATE TABLE IF NOT EXISTS master."EDID4" (
    "DOCNUM" VARCHAR(20) NOT NULL,
    "SEGNUM" VARCHAR(8)  NOT NULL,
    "MANDT"  INTEGER     NOT NULL,
    "SEGNAM" VARCHAR(8)  NOT NULL,
    "HLEVEL" INTEGER     NOT NULL,
    "PSGNUM" VARCHAR(8)  NOT NULL,
    "DTINT2" VARCHAR(3)  NULL,
    "SDATA"  VARCHAR(80) NOT NULL,
    CONSTRAINT "EDID4_pkey" PRIMARY KEY ("DOCNUM", "SEGNUM")
);

CREATE TABLE IF NOT EXISTS master."EDIDC" (
    "DOCNUM"    VARCHAR(20) NOT NULL,
    "MANDT"     INTEGER     NOT NULL,
    "DOCREL"    INTEGER     NOT NULL,
    "STATUS"    VARCHAR(2)  NOT NULL,
    "DOCTYP"    VARCHAR(30) NOT NULL,
    "MESTYP"    VARCHAR(20) NOT NULL,
    "SNDPRT"    VARCHAR(2)  NOT NULL,
    "SNDPRN"    VARCHAR(10) NOT NULL,
    "RCVPRT"    VARCHAR(2)  NOT NULL,
    "RCVPRN"    VARCHAR(10) NOT NULL,
    "CREDAT"    DATE        NOT NULL,
    "CRETIM"    VARCHAR(8)  NOT NULL,
    "DIRECT"    INTEGER     NOT NULL,
    "AVSID_REF" VARCHAR(15) NULL,
    "SC_SOURCE" VARCHAR(15) NOT NULL,
    CONSTRAINT "EDIDC_pkey" PRIMARY KEY ("DOCNUM")
);

CREATE TABLE IF NOT EXISTS master."Exception_Log" (
    "Source_Step"      VARCHAR(8)   NOT NULL,
    "SC"               VARCHAR(5)   NULL,
    "BUKRS"            VARCHAR(4)   NOT NULL,
    "KUNNR"            VARCHAR(10)  NOT NULL,
    "exception_type"   VARCHAR(20)  NULL,
    "detail"           VARCHAR(100) NULL,
    "raised_at_step"   VARCHAR(8)   NULL,
    "EXC_ID"           VARCHAR(15)  NULL,
    "REASON_CODE"      VARCHAR(30)  NULL,
    "SEVERITY"         VARCHAR(4)   NULL,
    "RAISED_AT"        TIMESTAMP    NULL,
    "DETAIL_2"         VARCHAR(255) NULL,
    "SC_ID"            VARCHAR(5)   NULL,
    "EXCEPTION_TYPE_2" VARCHAR(30)  NULL,
    "RAISED_AT_STEP_2" VARCHAR(8)   NULL
);

CREATE TABLE IF NOT EXISTS master."FAGLFLEXT" (
    "RBUKRS" VARCHAR(4)    NOT NULL,
    "RACCT"  INTEGER       NOT NULL,
    "RYEAR"  INTEGER       NOT NULL,
    "MONAT"  VARCHAR(2)    NOT NULL,
    "KTOSL"  VARCHAR(3)    NULL,
    "RCNTR"  VARCHAR(8)    NOT NULL,
    "PRCTR"  VARCHAR(8)    NOT NULL,
    "RBPLD"  VARCHAR(4)    NOT NULL,
    "DRCRK"  VARCHAR(1)    NOT NULL,
    "HSL"    NUMERIC(18,2) NOT NULL,
    "KSL"    NUMERIC(18,2) NOT NULL,
    CONSTRAINT "FAGLFLEXT_pkey" PRIMARY KEY ("RBUKRS", "RACCT", "RYEAR", "MONAT")
);

CREATE TABLE IF NOT EXISTS master."FEBCL" (
    "KUKEY" VARCHAR(20) NOT NULL,
    "ESNUM" VARCHAR(3)  NOT NULL,
    "BUKRS" VARCHAR(4)  NOT NULL,
    "BELNR" INTEGER     NOT NULL,
    "GJAHR" INTEGER     NOT NULL,
    CONSTRAINT "FEBCL_pkey" PRIMARY KEY ("KUKEY", "ESNUM")
);

CREATE TABLE IF NOT EXISTS master."FEBEP" (
    "ESNUM"     VARCHAR(3)  NOT NULL,
    "KUKEY"     VARCHAR(20) NOT NULL,
    "VGEXT"     VARCHAR(3)  NOT NULL,
    "BTRG"      INTEGER     NOT NULL,
    "WAERS"     VARCHAR(3)  NOT NULL,
    "GPART"     VARCHAR(30) NOT NULL,
    "VWEZW"     VARCHAR(50) NULL,
    "SC_SOURCE" VARCHAR(5)  NOT NULL,
    CONSTRAINT "FEBEP_pkey" PRIMARY KEY ("ESNUM", "KUKEY")
);

CREATE TABLE IF NOT EXISTS master."FEBKO" (
    "KUKEY"  VARCHAR(20) NOT NULL,
    "BUKRS"  VARCHAR(4)  NOT NULL,
    "HBKID"  VARCHAR(8)  NOT NULL,
    "KKEKZ"  INTEGER     NOT NULL,
    "BUDAT"  DATE        NOT NULL,
    "WAERS"  VARCHAR(3)  NOT NULL,
    "ANFSL"  INTEGER     NOT NULL,
    "SCHLU"  INTEGER     NOT NULL,
    CONSTRAINT "FEBKO_pkey" PRIMARY KEY ("KUKEY")
);

CREATE TABLE IF NOT EXISTS master."FEBLB" (
    "LOCKBOX"    VARCHAR(15) NOT NULL,
    "BATCH"      VARCHAR(10) NOT NULL,
    "BATCH_DATE" DATE        NOT NULL,
    "TOTAL"      INTEGER     NOT NULL,
    "ITEM_COUNT" INTEGER     NOT NULL,
    "SC_SOURCE"  VARCHAR(5)  NOT NULL,
    CONSTRAINT "FEBLB_pkey" PRIMARY KEY ("LOCKBOX", "BATCH")
);

CREATE TABLE IF NOT EXISTS master."FLB1" (
    "LOCKBOX"    VARCHAR(10) NOT NULL,
    "BATCH"      VARCHAR(15) NOT NULL,
    "BATCH_DATE" DATE        NOT NULL,
    "DEP_DATE"   DATE        NOT NULL,
    "HBKID"      VARCHAR(5)  NOT NULL,
    "WAERS"      VARCHAR(3)  NOT NULL,
    "BATCH_AMT"  INTEGER     NOT NULL,
    "ITEM_COUNT" INTEGER     NOT NULL,
    "FILE_NAME"  VARCHAR(20) NOT NULL,
    "IMPORT_TS"  TIMESTAMP   NOT NULL,
    "STATUS"     VARCHAR(10) NOT NULL,
    "SC_SOURCE"  VARCHAR(5)  NOT NULL,
    CONSTRAINT "FLB1_pkey" PRIMARY KEY ("LOCKBOX", "BATCH")
);

CREATE TABLE IF NOT EXISTS master."FLB2" (
    "BATCH"          VARCHAR(15)  NOT NULL,
    "ITEM_NO"        VARCHAR(3)   NOT NULL,
    "CHECK_NUMBER"   VARCHAR(10)  NOT NULL,
    "CHECK_DATE"     DATE         NOT NULL,
    "CHECK_AMOUNT"   INTEGER      NOT NULL,
    "KUNNR"          VARCHAR(10)  NOT NULL,
    "INVOICE_REF"    INTEGER      NOT NULL,
    "APPLIED_AMOUNT" INTEGER      NOT NULL,
    "REASON_CODE"    VARCHAR(255) NULL,
    "SGTXT"          VARCHAR(80)  NOT NULL,
    CONSTRAINT "FLB2_pkey" PRIMARY KEY ("BATCH", "ITEM_NO")
);

CREATE TABLE IF NOT EXISTS master."GLT0" (
    "RBUKRS" VARCHAR(4)    NOT NULL,
    "RACCT"  INTEGER       NOT NULL,
    "RYEAR"  INTEGER       NOT NULL,
    "KTOSL"  VARCHAR(3)    NULL,
    "MONAT"  VARCHAR(2)    NOT NULL,
    "DRCRK"  VARCHAR(1)    NOT NULL,
    "HSL"    NUMERIC(18,2) NOT NULL,
    "KSL"    NUMERIC(18,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS master."GLT0_PreCorrection_Snapshot" (
    "RBUKRS" VARCHAR(4)   NOT NULL,
    "RACCT"  INTEGER      NOT NULL,
    "RYEAR"  INTEGER      NOT NULL,
    "KTOSL"  VARCHAR(255) NULL,
    "MONAT"  VARCHAR(2)   NOT NULL,
    "DRCRK"  VARCHAR(1)   NOT NULL,
    "HSL"    INTEGER      NOT NULL,
    "KSL"    INTEGER      NOT NULL,
    "NOTE"   VARCHAR(255) NOT NULL,
    CONSTRAINT "GLT0_PreCorrection_Snapshot_pkey" PRIMARY KEY ("RBUKRS")
);

CREATE TABLE IF NOT EXISTS master."KNA1" (
    "KUNNR"     VARCHAR(10) NOT NULL,
    "NAME1"     VARCHAR(30) NOT NULL,
    "ORT01"     VARCHAR(15) NULL,
    "REGIO"     VARCHAR(3)  NULL,
    "LAND1"     VARCHAR(2)  NOT NULL,
    "KTOKD"     VARCHAR(4)  NOT NULL,
    "STRAS"     VARCHAR(30) NULL,
    "PSTLZ"     VARCHAR(8)  NULL,
    "TELF1"     VARCHAR(20) NULL,
    "SMTP_ADDR" VARCHAR(50) NULL,
    "XCPDK"     VARCHAR(1)  NULL,
    CONSTRAINT "KNA1_pkey" PRIMARY KEY ("KUNNR")
);

CREATE TABLE IF NOT EXISTS master."KNB1" (
    "KUNNR" VARCHAR(10) NOT NULL,
    "BUKRS" VARCHAR(4)  NOT NULL,
    "AKONT" INTEGER     NOT NULL,
    "ZUAWA" VARCHAR(3)  NOT NULL,
    "ZTERM" VARCHAR(5)  NOT NULL,
    "MAHNA" VARCHAR(4)  NULL,
    "TOGRU" VARCHAR(3)  NOT NULL,
    "KKBER" VARCHAR(4)  NOT NULL,
    "KLIMK" INTEGER     NOT NULL,
    "ZAHLS" VARCHAR(1)  NULL,
    CONSTRAINT "KNB1_pkey" PRIMARY KEY ("KUNNR", "BUKRS")
);

CREATE TABLE IF NOT EXISTS master."KNB4" (
    "KUNNR"               VARCHAR(10) NOT NULL,
    "BUKRS"               VARCHAR(4)  NOT NULL,
    "MUDAT"               DATE        NOT NULL,
    "avg_days_to_pay"     INTEGER     NOT NULL,
    "returned_checks_24m" INTEGER     NOT NULL,
    "max_dunning_24m"     INTEGER     NOT NULL,
    CONSTRAINT "KNB4_pkey" PRIMARY KEY ("KUNNR", "BUKRS")
);

CREATE TABLE IF NOT EXISTS master."KNB5" (
    "KUNNR" VARCHAR(10) NOT NULL,
    "BUKRS" VARCHAR(4)  NOT NULL,
    "MABER" VARCHAR(2)  NOT NULL,
    "MAHNA" VARCHAR(4)  NULL,
    "MAHNS" INTEGER     NOT NULL,
    "MADAT" DATE        NULL,
    CONSTRAINT "KNB5_pkey" PRIMARY KEY ("KUNNR", "BUKRS")
);

CREATE TABLE IF NOT EXISTS master."KNBK" (
    "KUNNR" VARCHAR(10)  NOT NULL,
    "BANKS" VARCHAR(2)   NOT NULL,
    "BANKL" VARCHAR(10)  NOT NULL,
    "BANKN" VARCHAR(30)  NOT NULL,
    "BKONT" VARCHAR(255) NULL,
    "KOINH" VARCHAR(30)  NOT NULL,
    "BVTYP" VARCHAR(4)   NOT NULL,
    CONSTRAINT "KNBK_pkey" PRIMARY KEY ("KUNNR")
);

CREATE TABLE IF NOT EXISTS master."KNC1" (
    "KUNNR" VARCHAR(10) NOT NULL,
    "BUKRS" VARCHAR(4)  NOT NULL,
    "GJAHR" INTEGER     NOT NULL,
    "UMSAV" INTEGER     NOT NULL,
    "UM01S" INTEGER     NOT NULL,
    "UM01H" INTEGER     NOT NULL,
    CONSTRAINT "KNC1_pkey" PRIMARY KEY ("KUNNR", "BUKRS")
);

CREATE TABLE IF NOT EXISTS master."KNVH" (
    "HITYP"  VARCHAR(1)  NOT NULL,
    "KUNNR"  VARCHAR(10) NOT NULL,
    "HKUNNR" VARCHAR(10) NOT NULL,
    "DATAB"  DATE        NOT NULL,
    "DATBI"  DATE        NOT NULL,
    CONSTRAINT "KNVH_pkey" PRIMARY KEY ("HITYP", "KUNNR")
);

CREATE TABLE IF NOT EXISTS master."LIKP" (
    "VBELN" VARCHAR(10) NOT NULL,
    "LFART" VARCHAR(2)  NOT NULL,
    "LFDAT" DATE        NOT NULL,
    "VKORG" VARCHAR(4)  NOT NULL,
    "WADAT" DATE        NOT NULL,
    "KUNNR" VARCHAR(10) NOT NULL,
    CONSTRAINT "LIKP_pkey" PRIMARY KEY ("VBELN")
);

CREATE TABLE IF NOT EXISTS master."LIPS" (
    "VBELN" VARCHAR(10)   NOT NULL,
    "POSNR" VARCHAR(8)    NOT NULL,
    "MATNR" VARCHAR(15)   NOT NULL,
    "LFIMG" INTEGER       NOT NULL,
    "VRKME" VARCHAR(2)    NOT NULL,
    "VGBEL" VARCHAR(10)   NOT NULL,
    "VGPOS" VARCHAR(8)    NOT NULL,
    "NETWR" NUMERIC(18,2) NOT NULL,
    CONSTRAINT "LIPS_pkey" PRIMARY KEY ("VBELN", "POSNR")
);

CREATE TABLE IF NOT EXISTS master."Lockbox_Config" (
    "Table"              VARCHAR(20) NOT NULL,
    "BUKRS"              VARCHAR(4)  NOT NULL,
    "LBOX_ID"            VARCHAR(15) NOT NULL,
    "Bank_Acct_Ctrl_Key" VARCHAR(10) NOT NULL,
    "Interpretation_Alg" VARCHAR(3)  NOT NULL,
    "Description_XPSTC"  VARCHAR(30) NOT NULL,
    CONSTRAINT "Lockbox_Config_pkey" PRIMARY KEY ("Table")
);

CREATE TABLE IF NOT EXISTS master."MHND" (
    "MAHNR" VARCHAR(8)   NOT NULL,
    "KUNNR" VARCHAR(10)  NOT NULL,
    "BUKRS" VARCHAR(4)   NOT NULL,
    "MAHNS" INTEGER      NOT NULL,
    "MADAT" DATE         NOT NULL,
    "NOTES" VARCHAR(255) NOT NULL,
    CONSTRAINT "MHND_pkey" PRIMARY KEY ("MAHNR")
);

CREATE TABLE IF NOT EXISTS master."MemoryMesh_Patterns" (
    "PATTERN_ID" VARCHAR(20)   NOT NULL,
    "SCOPE"      VARCHAR(80)   NOT NULL,
    "CONFIDENCE" NUMERIC(18,2) NOT NULL,
    "EVIDENCE"   VARCHAR(150)  NOT NULL,
    "APPLIES_TO" VARCHAR(150)  NOT NULL,
    CONSTRAINT "MemoryMesh_Patterns_pkey" PRIMARY KEY ("PATTERN_ID")
);

CREATE TABLE IF NOT EXISTS master."SKA1" (
    "SAKNR"       INTEGER     NOT NULL,
    "KTOPL"       VARCHAR(3)  NOT NULL,
    "MITKZ"       VARCHAR(1)  NULL,
    "XBILK"       VARCHAR(1)  NULL,
    "Description" VARCHAR(50) NOT NULL,
    CONSTRAINT "SKA1_pkey" PRIMARY KEY ("SAKNR")
);

CREATE TABLE IF NOT EXISTS master."SKAT" (
    "SAKNR" INTEGER     NOT NULL,
    "SPRAS" VARCHAR(1)  NOT NULL,
    "TEXT1" VARCHAR(50) NOT NULL,
    CONSTRAINT "SKAT_pkey" PRIMARY KEY ("SAKNR")
);

CREATE TABLE IF NOT EXISTS master."SKB1" (
    "SAKNR" INTEGER    NOT NULL,
    "BUKRS" VARCHAR(4) NOT NULL,
    "MITKZ" VARCHAR(1) NULL,
    "FSTAG" VARCHAR(4) NOT NULL,
    CONSTRAINT "SKB1_pkey" PRIMARY KEY ("SAKNR", "BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T001" (
    "BUKRS" VARCHAR(4)  NOT NULL,
    "BUTXT" VARCHAR(30) NOT NULL,
    "ORT01" VARCHAR(10) NOT NULL,
    "LAND1" VARCHAR(2)  NOT NULL,
    "WAERS" VARCHAR(3)  NOT NULL,
    "KTOPL" VARCHAR(3)  NOT NULL,
    "PERIV" VARCHAR(2)  NOT NULL,
    "MWSKV" VARCHAR(2)  NOT NULL,
    "KKBER" VARCHAR(4)  NOT NULL,
    CONSTRAINT "T001_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T001B" (
    "BUKRS" VARCHAR(4) NOT NULL,
    "MKOAR" VARCHAR(1) NOT NULL,
    "BUKAN" VARCHAR(4) NOT NULL,
    "UMNRA" VARCHAR(2) NOT NULL,
    "DATAB" DATE       NOT NULL,
    "DATBI" DATE       NOT NULL,
    CONSTRAINT "T001B_pkey" PRIMARY KEY ("BUKRS", "MKOAR", "BUKAN", "UMNRA", "DATAB")
);

CREATE TABLE IF NOT EXISTS master."T003" (
    "BLART" VARCHAR(2)  NOT NULL,
    "LTEXT" VARCHAR(30) NOT NULL,
    "NUMKR" VARCHAR(2)  NOT NULL,
    "XKOAR" VARCHAR(4)  NOT NULL,
    "XSTOV" VARCHAR(2)  NULL,
    CONSTRAINT "T003_pkey" PRIMARY KEY ("BLART")
);

CREATE TABLE IF NOT EXISTS master."T005" (
    "LAND1" VARCHAR(2)  NOT NULL,
    "LANDX" VARCHAR(15) NOT NULL,
    "NATIO" VARCHAR(15) NOT NULL,
    "INTCA" VARCHAR(2)  NOT NULL,
    CONSTRAINT "T005_pkey" PRIMARY KEY ("LAND1")
);

CREATE TABLE IF NOT EXISTS master."T005S" (
    "LAND1" VARCHAR(2)  NOT NULL,
    "BLAND" VARCHAR(3)  NOT NULL,
    "BEZEI" VARCHAR(20) NOT NULL,
    CONSTRAINT "T005S_pkey" PRIMARY KEY ("LAND1", "BLAND")
);

CREATE TABLE IF NOT EXISTS master."T007A" (
    "MWSKZ"       VARCHAR(2)  NOT NULL,
    "KALSM"       VARCHAR(5)  NOT NULL,
    "LAND"        VARCHAR(2)  NOT NULL,
    "Rate"        VARCHAR(8)  NOT NULL,
    "Description" VARCHAR(30) NOT NULL,
    CONSTRAINT "T007A_pkey" PRIMARY KEY ("MWSKZ")
);

CREATE TABLE IF NOT EXISTS master."T007S" (
    "MWSKZ" VARCHAR(2)  NOT NULL,
    "SPRAS" VARCHAR(1)  NOT NULL,
    "TEXT1" VARCHAR(30) NOT NULL,
    CONSTRAINT "T007S_pkey" PRIMARY KEY ("MWSKZ")
);

CREATE TABLE IF NOT EXISTS master."T012" (
    "BUKRS" VARCHAR(4)  NOT NULL,
    "HBKID" VARCHAR(8)  NOT NULL,
    "BANKS" VARCHAR(2)  NOT NULL,
    "BANKL" VARCHAR(10) NOT NULL,
    "BANKA" VARCHAR(30) NOT NULL,
    CONSTRAINT "T012_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T012K" (
    "BUKRS" VARCHAR(4)  NOT NULL,
    "HBKID" VARCHAR(8)  NOT NULL,
    "HKTID" VARCHAR(5)  NOT NULL,
    "BANKN" VARCHAR(10) NOT NULL,
    "WAERS" VARCHAR(3)  NOT NULL,
    "HKONT" INTEGER     NOT NULL,
    CONSTRAINT "T012K_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T028D" (
    "VGEXT"         VARCHAR(3)  NOT NULL,
    "Description"   VARCHAR(30) NOT NULL,
    "Internal_Type" VARCHAR(8)  NOT NULL,
    CONSTRAINT "T028D_pkey" PRIMARY KEY ("VGEXT")
);

CREATE TABLE IF NOT EXISTS master."T028G" (
    "Internal_Type" VARCHAR(8)  NOT NULL,
    "BSCHL_Debit"   INTEGER     NOT NULL,
    "BSCHL_Credit"  VARCHAR(2)  NULL,
    "HKONT"         INTEGER     NOT NULL,
    "Description"   VARCHAR(50) NOT NULL,
    CONSTRAINT "T028G_pkey" PRIMARY KEY ("Internal_Type")
);

CREATE TABLE IF NOT EXISTS master."T030" (
    "ktopl"     VARCHAR(4)   NOT NULL,
    "ktosl"     VARCHAR(4)   NOT NULL,
    "bschl"     VARCHAR(2)   NULL,
    "konth"     VARCHAR(10)  NULL,
    "konts"     VARCHAR(10)  NULL,
    "synced_at" TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT "T030_pkey" PRIMARY KEY ("ktopl", "ktosl")
);

CREATE TABLE IF NOT EXISTS master."T030B" (
    "BUKRS" VARCHAR(4) NOT NULL,
    "KTOSL" VARCHAR(3) NOT NULL,
    "KALSM" VARCHAR(5) NOT NULL,
    "KOSAR" VARCHAR(1) NOT NULL,
    "KONTO" INTEGER    NOT NULL,
    CONSTRAINT "T030B_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T040" (
    "BUKRS"       VARCHAR(4)  NOT NULL,
    "MABER"       VARCHAR(2)  NOT NULL,
    "Description" VARCHAR(30) NOT NULL,
    CONSTRAINT "T040_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T040A" (
    "MAHNA"    VARCHAR(4)  NOT NULL,
    "MAHNS"    INTEGER     NOT NULL,
    "TAGE"     INTEGER     NOT NULL,
    "TXTMA"    VARCHAR(30) NOT NULL,
    "Severity" VARCHAR(4)  NOT NULL,
    CONSTRAINT "T040A_pkey" PRIMARY KEY ("MAHNA", "MAHNS")
);

CREATE TABLE IF NOT EXISTS master."T040S" (
    "MAHNA"       VARCHAR(4)  NOT NULL,
    "Description" VARCHAR(50) NOT NULL,
    "Levels"      INTEGER     NOT NULL,
    CONSTRAINT "T040S_pkey" PRIMARY KEY ("MAHNA")
);

CREATE TABLE IF NOT EXISTS master."T043" (
    "bukrs"     VARCHAR(4)    NOT NULL,
    "togru"     VARCHAR(4)    NOT NULL,
    "waers"     VARCHAR(5)    NOT NULL,
    "betrg"     NUMERIC(13,2) NOT NULL DEFAULT 0.00,
    "wrbtr"     NUMERIC(13,2) NOT NULL DEFAULT 0.00,
    "prztl"     NUMERIC(5,2)  NOT NULL DEFAULT 0.00,
    "prznr"     NUMERIC(5,2)  NOT NULL DEFAULT 0.00,
    "synced_at" TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT "T043_pkey" PRIMARY KEY ("bukrs", "togru")
);

CREATE TABLE IF NOT EXISTS master."T052" (
    "ZTERM"       VARCHAR(5)  NOT NULL,
    "Description" VARCHAR(30) NOT NULL,
    "Net_Days"    INTEGER     NOT NULL,
    "Disc_1_pct"  VARCHAR(5)  NOT NULL,
    "Days_Disc_1" INTEGER     NOT NULL,
    "Disc_2_pct"  VARCHAR(5)  NOT NULL,
    "Days_Disc_2" INTEGER     NOT NULL,
    CONSTRAINT "T052_pkey" PRIMARY KEY ("ZTERM")
);

CREATE TABLE IF NOT EXISTS master."T053" (
    "rstgr"     VARCHAR(6)   NOT NULL,
    "ltext"     VARCHAR(80)  NOT NULL,
    "hkont"     VARCHAR(10)  NULL,
    "koart"     CHAR(1)      NOT NULL DEFAULT 'D',
    "xauto"     BOOLEAN      NOT NULL DEFAULT FALSE,
    "postg"     CHAR(1)      NULL,
    "synced_at" TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT "T053_pkey" PRIMARY KEY ("rstgr")
);

CREATE TABLE IF NOT EXISTS master."T077D" (
    "KTOKD"       VARCHAR(4)  NOT NULL,
    "Description" VARCHAR(30) NOT NULL,
    CONSTRAINT "T077D_pkey" PRIMARY KEY ("KTOKD")
);

CREATE TABLE IF NOT EXISTS master."T169G" (
    "BUKRS"             VARCHAR(4) NOT NULL,
    "TOGGR"             VARCHAR(2) NOT NULL,
    "Diff_Allowed_Gain" INTEGER    NOT NULL,
    "Diff_Allowed_Loss" INTEGER    NOT NULL,
    CONSTRAINT "T169G_pkey" PRIMARY KEY ("BUKRS")
);

CREATE TABLE IF NOT EXISTS master."T169P" (
    "BUKRS"            VARCHAR(4) NOT NULL,
    "TOGRU"            VARCHAR(3) NOT NULL,
    "XGTOL_pct"        VARCHAR(5) NOT NULL,
    "XKTOL_pct"        VARCHAR(5) NOT NULL,
    "Disc_Allowed_pct" VARCHAR(5) NOT NULL,
    "Diff_Gain"        INTEGER    NOT NULL,
    "Diff_Loss"        INTEGER    NOT NULL,
    CONSTRAINT "T169P_pkey" PRIMARY KEY ("BUKRS", "TOGRU")
);

CREATE TABLE IF NOT EXISTS master."TBSL" (
    "BSCHL"       VARCHAR(2)  NOT NULL,
    "KOART"       VARCHAR(1)  NOT NULL,
    "SHKZG"       VARCHAR(1)  NOT NULL,
    "Description" VARCHAR(50) NOT NULL,
    CONSTRAINT "TBSL_pkey" PRIMARY KEY ("BSCHL")
);

CREATE TABLE IF NOT EXISTS master."TCURC" (
    "WAERS"       VARCHAR(3)  NOT NULL,
    "ISOCD"       VARCHAR(3)  NOT NULL,
    "Description" VARCHAR(50) NOT NULL,
    CONSTRAINT "TCURC_pkey" PRIMARY KEY ("WAERS")
);

CREATE TABLE IF NOT EXISTS master."TCURF" (
    "KURST" VARCHAR(1) NOT NULL,
    "FCURR" VARCHAR(3) NOT NULL,
    "TCURR" VARCHAR(3) NOT NULL,
    "GDATU" DATE       NOT NULL,
    "FFACT" INTEGER    NOT NULL,
    "TFACT" INTEGER    NOT NULL,
    CONSTRAINT "TCURF_pkey" PRIMARY KEY ("KURST", "FCURR", "TCURR")
);

CREATE TABLE IF NOT EXISTS master."TCURR" (
    "KURST" VARCHAR(1)    NOT NULL,
    "FCURR" VARCHAR(3)    NOT NULL,
    "TCURR" VARCHAR(3)    NOT NULL,
    "GDATU" DATE          NOT NULL,
    "UKURS" NUMERIC(18,6) NOT NULL,
    CONSTRAINT "TCURR_pkey" PRIMARY KEY ("KURST", "FCURR", "TCURR", "GDATU")
);

CREATE TABLE IF NOT EXISTS master."TCURV" (
    "KURST" VARCHAR(1)   NOT NULL,
    "XINVR" VARCHAR(255) NULL,
    "BWAER" VARCHAR(3)   NOT NULL,
    CONSTRAINT "TCURV_pkey" PRIMARY KEY ("KURST")
);

CREATE TABLE IF NOT EXISTS master."TCURX" (
    "CURRKEY" VARCHAR(3) NOT NULL,
    "CURRDEC" INTEGER    NOT NULL,
    CONSTRAINT "TCURX_pkey" PRIMARY KEY ("CURRKEY")
);

CREATE TABLE IF NOT EXISTS master."VBAK" (
    "VBELN" VARCHAR(10)   NOT NULL,
    "AUART" VARCHAR(2)    NOT NULL,
    "AUDAT" DATE          NOT NULL,
    "VKORG" VARCHAR(4)    NOT NULL,
    "VTWEG" VARCHAR(2)    NOT NULL,
    "SPART" VARCHAR(2)    NOT NULL,
    "KUNNR" VARCHAR(10)   NOT NULL,
    "WAERK" VARCHAR(3)    NOT NULL,
    "NETWR" NUMERIC(18,2) NOT NULL,
    CONSTRAINT "VBAK_pkey" PRIMARY KEY ("VBELN")
);

CREATE TABLE IF NOT EXISTS master."VBAP" (
    "VBELN"  VARCHAR(10)   NOT NULL,
    "POSNR"  VARCHAR(8)    NOT NULL,
    "MATNR"  VARCHAR(15)   NOT NULL,
    "ARKTX"  VARCHAR(15)   NOT NULL,
    "KWMENG" INTEGER       NOT NULL,
    "VRKME"  VARCHAR(2)    NOT NULL,
    "NETWR"  NUMERIC(18,2) NOT NULL,
    "WAERK"  VARCHAR(3)    NOT NULL,
    "PSTYV"  VARCHAR(3)    NOT NULL,
    CONSTRAINT "VBAP_pkey" PRIMARY KEY ("VBELN", "POSNR")
);

CREATE TABLE IF NOT EXISTS master."VBFA" (
    "VBELV"   VARCHAR(10) NOT NULL,
    "POSNV"   VARCHAR(8)  NOT NULL,
    "VBELN"   VARCHAR(10) NOT NULL,
    "POSNN"   VARCHAR(8)  NOT NULL,
    "VBTYP_N" VARCHAR(1)  NOT NULL,
    "VBTYP_V" VARCHAR(1)  NOT NULL,
    "RFMNG"   INTEGER     NOT NULL,
    CONSTRAINT "VBFA_pkey" PRIMARY KEY ("VBELV", "POSNV", "VBELN")
);

CREATE TABLE IF NOT EXISTS master."VBRK" (
    "VBELN" VARCHAR(10)   NOT NULL,
    "FKART" VARCHAR(2)    NOT NULL,
    "FKDAT" DATE          NOT NULL,
    "VKORG" VARCHAR(4)    NOT NULL,
    "KUNAG" VARCHAR(10)   NOT NULL,
    "WAERK" VARCHAR(3)    NOT NULL,
    "NETWR" NUMERIC(18,2) NOT NULL,
    "MWSBK" NUMERIC(18,2) NOT NULL,
    "FKSTO" VARCHAR(255)  NULL,
    CONSTRAINT "VBRK_pkey" PRIMARY KEY ("VBELN")
);

CREATE TABLE IF NOT EXISTS master."VBRP" (
    "VBELN" VARCHAR(10)   NOT NULL,
    "POSNR" VARCHAR(8)    NOT NULL,
    "MATNR" VARCHAR(15)   NOT NULL,
    "FKIMG" INTEGER       NOT NULL,
    "VRKME" VARCHAR(2)    NULL,
    "NETWR" NUMERIC(18,2) NOT NULL,
    "MWSBP" NUMERIC(18,2) NOT NULL,
    "AUBEL" VARCHAR(10)   NOT NULL,
    "AUPOS" VARCHAR(8)    NULL,
    CONSTRAINT "VBRP_pkey" PRIMARY KEY ("VBELN", "POSNR")
);

CREATE TABLE IF NOT EXISTS master."_VALIDATION_RESULTS" (
    "Rule"     VARCHAR(8)   NOT NULL,
    "Severity" VARCHAR(5)   NOT NULL,
    "Check"    VARCHAR(80)  NOT NULL,
    "Result"   VARCHAR(4)   NOT NULL,
    "Total"    INTEGER      NOT NULL,
    "Failures" INTEGER      NOT NULL,
    "Detail"   VARCHAR(100) NOT NULL,
    CONSTRAINT "_VALIDATION_RESULTS_pkey" PRIMARY KEY ("Rule")
);


-- ============================================================
-- CASHAPP SCHEMA — HYBRID TABLES
-- All transactional application tables converted to HYBRID.
-- Supports ACID, row-level locking, fast single-row DML.
-- CHECK constraints removed — not enforced in Snowflake hybrid
-- tables; enforcement moves to application/Snowpark layer.
-- ============================================================

USE SCHEMA cashapp;

CREATE SEQUENCE IF NOT EXISTS customer_match_patterns_pattern_id_seq;

-- channels is a small lookup table — kept as HYBRID for
-- consistency with the schema and to support FK references
-- from other hybrid tables in the same schema.
CREATE HYBRID TABLE IF NOT EXISTS channels (
    channel_id   SMALLINT     NOT NULL,
    channel_code VARCHAR(20)  NOT NULL,
    channel_name VARCHAR(50)  NOT NULL,
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT channels_pkey             PRIMARY KEY (channel_id),
    CONSTRAINT channels_channel_code_key UNIQUE (channel_code)
);

CREATE HYBRID TABLE IF NOT EXISTS channel_captures (
    capture_id            VARCHAR(36)   NOT NULL DEFAULT UUID_STRING(),
    channel_id            SMALLINT      NOT NULL,
    source_reference_id   VARCHAR(100)  NOT NULL,
    payer_name            VARCHAR(255)  NULL,
    payer_bank_account    VARCHAR(50)   NULL,
    payer_bank_code       VARCHAR(20)   NULL,
    payment_amount        NUMERIC(18,2) NOT NULL,
    currency              VARCHAR(5)    NOT NULL,
    payment_date          DATE          NULL,
    extraction_method     VARCHAR(30)   NOT NULL,
    extraction_confidence NUMERIC(4,3)  NULL,
    validation_status     VARCHAR(30)   NOT NULL DEFAULT 'PENDING_VALIDATION',
    capture_status        VARCHAR(30)   NOT NULL DEFAULT 'PENDING',
    case_id               VARCHAR(36)   NULL,
    payment_reference     VARCHAR(50)   NULL,
    created_at            TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    updated_at            TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT channel_captures_pkey        PRIMARY KEY (capture_id),
    CONSTRAINT uq_channel_captures_source   UNIQUE (channel_id, source_reference_id),
    CONSTRAINT channel_captures_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES channels (channel_id)
    -- NOTE: FK on case_id → cases(case_id) omitted due to circular dependency
    --       (cases also references channel_captures). Enforced at application level.
);

CREATE INDEX IF NOT EXISTS idx_channel_captures_channel_id      ON channel_captures (channel_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_channel_captures_validation_status ON channel_captures (validation_status);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_channel_captures_capture_status  ON channel_captures (capture_status);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_channel_captures_case_id         ON channel_captures (case_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_channel_captures_payment_date    ON channel_captures (payment_date);

CREATE HYBRID TABLE IF NOT EXISTS payments (
    payment_id        VARCHAR(36)   NOT NULL DEFAULT UUID_STRING(),
    capture_id        VARCHAR(36)   NOT NULL,
    sap_customer_id   VARCHAR(10)   NULL,
    payment_reference VARCHAR(100)  NULL,
    bank_reference    VARCHAR(255)  NULL,
    payment_amount    NUMERIC(18,2) NOT NULL,
    applied_amount    NUMERIC(18,2) NOT NULL DEFAULT 0,
    unapplied_amount  NUMERIC(18,2) NOT NULL DEFAULT 0,
    currency_code     VARCHAR(5)    NOT NULL DEFAULT 'USD',
    payment_date      DATE          NULL,
    payment_status    VARCHAR(20)   NOT NULL DEFAULT 'NEW',
    created_at        TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    updated_at        TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT payments_pkey PRIMARY KEY (payment_id),
    CONSTRAINT payments_capture_id_fkey FOREIGN KEY (capture_id) REFERENCES channel_captures (capture_id)
);

CREATE INDEX IF NOT EXISTS idx_payments_capture_id    ON payments (capture_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_payments_status        ON payments (payment_status);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_payments_sap_customer  ON payments (sap_customer_id);

CREATE HYBRID TABLE IF NOT EXISTS cases (
    case_id               VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    case_number           VARCHAR(30)       NOT NULL,
    capture_id            VARCHAR(36)       NOT NULL,
    payment_id            VARCHAR(36)       NULL,
    sap_customer_id       VARCHAR(20)       NULL,
    case_status           VARCHAR(20)       NOT NULL DEFAULT 'OPEN',
    workflow_stage        VARCHAR(30)       NULL,
    priority_level        VARCHAR(10)       NULL,
    payment_amount        NUMERIC(18,2)     NULL,
    currency_code         VARCHAR(5)        NULL,
    resolution_layer      VARCHAR(30)       NULL,
    resolution_confidence NUMERIC(4,3)      NULL,
    match_strategy        VARCHAR(20)       NULL,
    match_confidence      NUMERIC(4,3)      NULL,
    review_autonomy_tier  VARCHAR(10)       NULL,
    autonomy_tier         VARCHAR(10)       NULL,
    approval_status       VARCHAR(20)       NULL,
    assigned_to           VARCHAR(255)      NULL,
    ai_confidence         NUMERIC(4,3)      NULL,
    ai_summary_title      VARCHAR(255)      NULL,
    ai_summary            VARCHAR(16777216) NULL,
    sap_document_number   VARCHAR(20)       NULL,
    sap_company_code      VARCHAR(4)        NULL,
    sap_fiscal_year       VARCHAR(4)        NULL,
    route_reason          VARCHAR(16777216) NULL,
    awkey                 VARCHAR(32)       NULL,
    postguard_status      VARCHAR(20)       NULL,
    postguard_results     VARIANT           NULL,
    escalation_tier       VARCHAR(10)       NULL,
    posting_attempts      INTEGER           NULL DEFAULT 0,
    posting_exception_type VARCHAR(20)      NULL,
    closure_reason        VARCHAR(20)       NULL,
    created_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    updated_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    closed_at             TIMESTAMP_TZ      NULL,
    CONSTRAINT cases_pkey              PRIMARY KEY (case_id),
    CONSTRAINT cases_case_number_key   UNIQUE (case_number),
    CONSTRAINT uq_cases_capture_id     UNIQUE (capture_id),
    CONSTRAINT cases_capture_id_fkey   FOREIGN KEY (capture_id) REFERENCES channel_captures (capture_id),
    CONSTRAINT cases_payment_id_fkey   FOREIGN KEY (payment_id) REFERENCES payments (payment_id)
);

CREATE INDEX IF NOT EXISTS idx_cases_case_status     ON cases (case_status);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_workflow_stage  ON cases (workflow_stage);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_priority_level  ON cases (priority_level);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_sap_customer_id ON cases (sap_customer_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_capture_id      ON cases (capture_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_payment_id      ON cases (payment_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_awkey           ON cases (awkey);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_approval_status ON cases (approval_status);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_cases_escalation_tier ON cases (escalation_tier);

CREATE HYBRID TABLE IF NOT EXISTS capture_runs (
    run_id          VARCHAR(36)  NOT NULL DEFAULT UUID_STRING(),
    channel_id      SMALLINT     NOT NULL,
    started_at      TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    finished_at     TIMESTAMP_TZ NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'RUNNING',
    batch_size      INTEGER      NULL,
    items_attempted INTEGER      NOT NULL DEFAULT 0,
    items_captured  INTEGER      NOT NULL DEFAULT 0,
    items_skipped   INTEGER      NOT NULL DEFAULT 0,
    items_errored   INTEGER      NOT NULL DEFAULT 0,
    cursor_start    VARCHAR(255) NULL,
    cursor_end      VARCHAR(255) NULL,
    CONSTRAINT capture_runs_pkey PRIMARY KEY (run_id),
    CONSTRAINT capture_runs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES channels (channel_id)
);

CREATE INDEX IF NOT EXISTS idx_capture_runs_channel_id ON capture_runs (channel_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_capture_runs_status     ON capture_runs (status);

CREATE HYBRID TABLE IF NOT EXISTS capture_error_log (
    error_id            VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    run_id              VARCHAR(36)       NOT NULL,
    channel_id          SMALLINT          NOT NULL,
    source_reference_id VARCHAR(255)      NOT NULL,
    attempt_number      INTEGER           NOT NULL,
    error_type          VARCHAR(50)       NOT NULL,
    error_message       VARCHAR(16777216) NULL,
    error_detail        VARIANT           NULL,
    is_resolved         BOOLEAN           NOT NULL DEFAULT FALSE,
    resolved_at         TIMESTAMP_TZ      NULL,
    created_at          TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT capture_error_log_pkey PRIMARY KEY (error_id),
    CONSTRAINT capture_error_log_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES channels (channel_id),
    CONSTRAINT capture_error_log_run_id_fkey FOREIGN KEY (run_id) REFERENCES capture_runs (run_id)
);

CREATE INDEX IF NOT EXISTS idx_capture_error_log_run_id     ON capture_error_log (run_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_capture_error_log_channel_id ON capture_error_log (channel_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_capture_error_log_is_resolved ON capture_error_log (is_resolved);

CREATE HYBRID TABLE IF NOT EXISTS capture_source_documents (
    document_id           VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    capture_id            VARCHAR(36)       NOT NULL,
    channel_id            SMALLINT          NOT NULL,
    document_type         VARCHAR(30)       NOT NULL,
    original_filename     VARCHAR(255)      NULL,
    mime_type             VARCHAR(100)      NULL,
    file_size_bytes       BIGINT            NULL,
    storage_path          VARCHAR(500)      NULL,
    extraction_status     VARCHAR(20)       NOT NULL DEFAULT 'PENDING',
    extraction_provider   VARCHAR(30)       NOT NULL,
    extraction_confidence NUMERIC(4,3)      NULL,
    parsed_content        VARIANT           NULL,
    extraction_error      VARCHAR(16777216) NULL,
    created_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    updated_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT capture_source_documents_pkey PRIMARY KEY (document_id),
    CONSTRAINT capture_source_documents_capture_id_fkey FOREIGN KEY (capture_id) REFERENCES channel_captures (capture_id),
    CONSTRAINT capture_source_documents_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES channels (channel_id)
);

CREATE INDEX IF NOT EXISTS idx_capture_source_docs_capture_id        ON capture_source_documents (capture_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_capture_source_docs_channel_id        ON capture_source_documents (channel_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_capture_source_docs_extraction_status ON capture_source_documents (extraction_status);

CREATE HYBRID TABLE IF NOT EXISTS capture_remittance_claims (
    claim_id              VARCHAR(36)   NOT NULL DEFAULT UUID_STRING(),
    capture_id            VARCHAR(36)   NOT NULL,
    invoice_number        VARCHAR(50)   NOT NULL,
    invoice_date          DATE          NULL,
    gross_amount          NUMERIC(18,2) NULL,
    deduction_amount      NUMERIC(18,2) NOT NULL DEFAULT 0,
    net_amount            NUMERIC(18,2) NULL,
    currency              VARCHAR(5)    NULL,
    reason_code           VARCHAR(10)   NULL,
    po_number             VARCHAR(50)   NULL,
    extraction_confidence NUMERIC(4,3)  NULL,
    source_document_id    VARCHAR(36)   NULL,
    created_at            TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT capture_remittance_claims_pkey PRIMARY KEY (claim_id),
    CONSTRAINT capture_remittance_claims_capture_id_fkey FOREIGN KEY (capture_id) REFERENCES channel_captures (capture_id),
    CONSTRAINT capture_remittance_claims_source_document_id_fkey FOREIGN KEY (source_document_id) REFERENCES capture_source_documents (document_id)
);

CREATE INDEX IF NOT EXISTS idx_capture_remittance_claims_capture_id     ON capture_remittance_claims (capture_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_capture_remittance_claims_invoice_number ON capture_remittance_claims (invoice_number);

CREATE HYBRID TABLE IF NOT EXISTS channel_sync_cursors (
    channel_id        SMALLINT          NOT NULL,
    last_processed_id VARCHAR(100)      NULL,
    last_processed_at TIMESTAMP_TZ      NULL,
    sync_status       VARCHAR(20)       NOT NULL DEFAULT 'IDLE',
    error_message     VARCHAR(16777216) NULL,
    updated_at        TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT channel_sync_cursors_pkey PRIMARY KEY (channel_id),
    CONSTRAINT channel_sync_cursors_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES channels (channel_id)
);

CREATE HYBRID TABLE IF NOT EXISTS case_events (
    event_id      VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    case_id       VARCHAR(36)       NOT NULL,
    event_type    VARCHAR(50)       NOT NULL,
    event_message VARCHAR(16777216) NULL,
    event_data    VARIANT           NULL,
    occurred_at   TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT case_events_pkey PRIMARY KEY (event_id),
    CONSTRAINT case_events_case_id_fkey FOREIGN KEY (case_id) REFERENCES cases (case_id)
);

CREATE INDEX IF NOT EXISTS idx_case_events_case_id    ON case_events (case_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_case_events_event_type ON case_events (event_type);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_case_events_occurred_at ON case_events (occurred_at);

CREATE HYBRID TABLE IF NOT EXISTS case_match_proposals (
    proposal_id          VARCHAR(36)   NOT NULL DEFAULT UUID_STRING(),
    case_id              VARCHAR(36)   NOT NULL,
    proposal_rank        SMALLINT      NOT NULL DEFAULT 1,
    is_selected          BOOLEAN       NOT NULL DEFAULT FALSE,
    match_strategy       VARCHAR(20)   NULL,
    match_confidence     NUMERIC(4,3)  NULL,
    total_invoice_amount NUMERIC(18,2) NULL,
    total_payment_amount NUMERIC(18,2) NULL,
    variance_amount      NUMERIC(18,2) NULL,
    variance_currency    VARCHAR(5)    NULL,
    variance_type        VARCHAR(20)   NULL,
    tolerance_group      VARCHAR(4)    NULL,
    posting_date         DATE          NULL,
    postguard_results    VARIANT       NULL,
    created_at           TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT case_match_proposals_pkey PRIMARY KEY (proposal_id),
    CONSTRAINT case_match_proposals_case_id_fkey FOREIGN KEY (case_id) REFERENCES cases (case_id)
);

CREATE INDEX IF NOT EXISTS idx_case_match_proposals_case_id     ON case_match_proposals (case_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_case_match_proposals_is_selected ON case_match_proposals (case_id, is_selected);

CREATE HYBRID TABLE IF NOT EXISTS case_postguard_checks (
    check_id       VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    case_id        VARCHAR(36)       NOT NULL,
    run_at         TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    check_sequence SMALLINT          NOT NULL,
    check_name     VARCHAR(30)       NOT NULL,
    passed         BOOLEAN           NOT NULL,
    reason_code    VARCHAR(30)       NULL,
    detail         VARCHAR(16777216) NULL,
    check_data     VARIANT           NULL,
    CONSTRAINT case_postguard_checks_pkey PRIMARY KEY (check_id),
    CONSTRAINT case_postguard_checks_case_id_fkey FOREIGN KEY (case_id) REFERENCES cases (case_id)
);

CREATE INDEX IF NOT EXISTS idx_case_postguard_checks_case_id   ON case_postguard_checks (case_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_case_postguard_checks_name_pass ON case_postguard_checks (check_name, passed);

CREATE HYBRID TABLE IF NOT EXISTS case_invoice_matches (
    match_id              VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    proposal_id           VARCHAR(36)       NOT NULL,
    case_id               VARCHAR(36)       NOT NULL,
    company_code          VARCHAR(4)        NULL,
    customer_number       VARCHAR(10)       NULL,
    fiscal_year           INTEGER           NULL,
    document_number       INTEGER           NULL,
    line_item             VARCHAR(3)        NULL,
    invoice_amount        NUMERIC(18,2)     NULL,
    deduction_amount      NUMERIC(18,2)     NOT NULL DEFAULT 0,
    deduction_reason_code VARCHAR(10)       NULL,
    net_amount            NUMERIC(18,2)     NULL,
    currency              VARCHAR(5)        NULL,
    match_layer           SMALLINT          NULL,
    l1_score              NUMERIC(4,3)      NULL,
    l2_score              NUMERIC(4,3)      NULL,
    l3_score              NUMERIC(4,3)      NULL,
    l4_score              NUMERIC(4,3)      NULL,
    confidence            NUMERIC(4,3)      NULL,
    reasoning             VARCHAR(16777216) NULL,
    is_included           BOOLEAN           NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT case_invoice_matches_pkey PRIMARY KEY (match_id),
    CONSTRAINT case_invoice_matches_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES case_match_proposals (proposal_id),
    CONSTRAINT case_invoice_matches_case_id_fkey FOREIGN KEY (case_id) REFERENCES cases (case_id)
);

CREATE INDEX IF NOT EXISTS idx_case_invoice_matches_proposal_id ON case_invoice_matches (proposal_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_case_invoice_matches_case_id     ON case_invoice_matches (case_id);

CREATE HYBRID TABLE IF NOT EXISTS customer_match_patterns (
    pattern_id     INTEGER           NOT NULL DEFAULT customer_match_patterns_pattern_id_seq.NEXTVAL,
    customer_kunnr VARCHAR(10)       NOT NULL,
    bukrs          VARCHAR(4)        NOT NULL,
    pattern_type   VARCHAR(20)       NOT NULL,
    pattern_value  VARCHAR(16777216) NULL,
    is_active      BOOLEAN           NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT customer_match_patterns_pkey PRIMARY KEY (pattern_id)
);

CREATE INDEX IF NOT EXISTS idx_customer_match_patterns_kunnr ON customer_match_patterns (customer_kunnr);

CREATE HYBRID TABLE IF NOT EXISTS system_config (
    config_id    VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    company_code VARCHAR(4)        NULL,
    config_key   VARCHAR(100)      NOT NULL,
    config_value VARCHAR(255)      NOT NULL,
    description  VARCHAR(16777216) NULL,
    updated_by   VARCHAR(255)      NULL,
    updated_at   TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT system_config_pkey                          PRIMARY KEY (config_id),
    CONSTRAINT system_config_company_code_config_key_key   UNIQUE (company_code, config_key)
);



-- ============================================================
-- CASHAPP_AUTHDB SCHEMA — HYBRID TABLES
-- Auth tables require fast single-row reads/writes for login,
-- token validation, and session management.
-- ============================================================

USE SCHEMA cashapp_authdb;

CREATE HYBRID TABLE IF NOT EXISTS novigo_auth_alembic_version (
    version_num VARCHAR(32) NOT NULL,
    CONSTRAINT novigo_auth_alembic_version_pkc PRIMARY KEY (version_num)
);

CREATE HYBRID TABLE IF NOT EXISTS novigo_users (
    id                    VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    username              VARCHAR(255)      NOT NULL,
    email                 VARCHAR(255)      NOT NULL,
    password_hash         VARCHAR(16777216) NOT NULL,
    is_active             BOOLEAN           NOT NULL DEFAULT TRUE,
    failed_login_attempts INTEGER           NOT NULL DEFAULT 0,
    locked_until          TIMESTAMP_TZ      NULL,
    created_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    updated_at            TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT novigo_users_pkey PRIMARY KEY (id),
    CONSTRAINT ix_novigo_users_email UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS idx_novigo_users_email    ON novigo_users (email);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_novigo_users_username ON novigo_users (username);

CREATE HYBRID TABLE IF NOT EXISTS novigo_roles (
    id          VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    name        VARCHAR(100)      NOT NULL,
    description VARCHAR(16777216) NULL,
    created_at  TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT novigo_roles_pkey PRIMARY KEY (id),
    CONSTRAINT ix_novigo_roles_name UNIQUE (name)
);

CREATE INDEX IF NOT EXISTS idx_novigo_roles_name ON novigo_roles (name);

CREATE HYBRID TABLE IF NOT EXISTS novigo_refresh_tokens (
    id         VARCHAR(36)       NOT NULL DEFAULT UUID_STRING(),
    user_id    VARCHAR(36)       NOT NULL,
    token_hash VARCHAR(16777216) NOT NULL,
    expires_at TIMESTAMP_TZ      NOT NULL,
    is_revoked BOOLEAN           NOT NULL DEFAULT FALSE,
    revoked_at TIMESTAMP_TZ      NULL,
    created_at TIMESTAMP_TZ      NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT novigo_refresh_tokens_pkey PRIMARY KEY (id),
    CONSTRAINT novigo_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES novigo_users (id),
    CONSTRAINT ix_novigo_refresh_tokens_hash UNIQUE (token_hash)
);

CREATE INDEX IF NOT EXISTS idx_novigo_refresh_tokens_user_id    ON novigo_refresh_tokens (user_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_novigo_refresh_tokens_is_revoked ON novigo_refresh_tokens (is_revoked);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_novigo_refresh_tokens_expires_at ON novigo_refresh_tokens (expires_at);

CREATE HYBRID TABLE IF NOT EXISTS novigo_revoked_tokens (
    id         VARCHAR(36)  NOT NULL DEFAULT UUID_STRING(),
    jti        VARCHAR(64)  NOT NULL,
    expires_at TIMESTAMP_TZ NOT NULL,
    revoked_at TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT novigo_revoked_tokens_pkey PRIMARY KEY (id),
    CONSTRAINT ix_novigo_revoked_tokens_jti UNIQUE (jti)
);

CREATE INDEX IF NOT EXISTS idx_novigo_revoked_tokens_jti        ON novigo_revoked_tokens (jti);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_novigo_revoked_tokens_expires_at ON novigo_revoked_tokens (expires_at);

CREATE HYBRID TABLE IF NOT EXISTS novigo_user_roles (
    user_id     VARCHAR(36)  NOT NULL,
    role_id     VARCHAR(36)  NOT NULL,
    assigned_at TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT novigo_user_roles_pkey PRIMARY KEY (user_id, role_id),
    CONSTRAINT novigo_user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES novigo_users (id),
    CONSTRAINT novigo_user_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES novigo_roles (id)
);

CREATE INDEX IF NOT EXISTS idx_novigo_user_roles_user_id ON novigo_user_roles (user_id);
CALL SYSTEM$WAIT(5, 'SECONDS');
CREATE INDEX IF NOT EXISTS idx_novigo_user_roles_role_id ON novigo_user_roles (role_id);