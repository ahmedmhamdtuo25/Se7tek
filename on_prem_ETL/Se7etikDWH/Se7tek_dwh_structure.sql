-- ============================================================
--  Se7tek Pregnancy Care — DATA WAREHOUSE
--  Star Schema  |  SQL Server (T-SQL)
--  Database : Se7tek_DWH
-- ============================================================
--
--  LAYER ORDER :
--    0. Database + schema
--    1. Dim_Date            (no FK dependencies)
--    2. Dim_Analysis_Type   (no FK dependencies)
--    3. Dim_Alert           (no FK dependencies)
--    4. Dim_Content         (no FK dependencies)
--    5. Dim_Medication      (no FK dependencies)
--    6. Dim_Doctor          (no FK dependencies)
--    7. Dim_Patient         (SCD2 — no FK to other dims)
--    8. Dim_Pregnancy       (SCD2 — FK to Dim_Patient)
--    9. Fact_Appointments
--   10. Fact_Medical_Analysis_Results
--   11. Fact_Medication_Adherence
--   12. Fact_Alert_Response
--   13. Fact_Content_Views
--   14. Fact_Pregnancy_Monitoring  (accumulating snapshot)
--   15. DWH Indexes
--   16. ETL stored procedures  (one per dim/fact)
--   17. Verification queries
--
--  DESIGN NOTES
--  ─────────────────────────────────────────────────────────
--  * All surrogate PKs are named <Table>Key (INT IDENTITY).
--  * All source (OLTP) natural keys are kept as <Entity>ID
--    columns so ETL can always join back to the source.
--  * Dim_Patient and Dim_Pregnancy use SCD Type 2:
--      Valid_From  = date the row became current
--      Valid_To    = date the row was superseded (9999-12-31
--                    means it is still the current row)
--      Is_Current  = 1 for the active row, 0 for history
--  * Fact grains:
--      Fact_Appointments              — one row per appointment
--      Fact_Medical_Analysis_Results  — one row per lab result
--      Fact_Medication_Adherence      — one row per scheduled dose
--      Fact_Alert_Response            — one row per raised alert
--      Fact_Content_Views             — one row per view event
--      Fact_Pregnancy_Monitoring      — one row per pregnancy
--                                       (accumulating snapshot,
--                                        updated as milestones
--                                        are reached)
-- ============================================================

-- ============================================================
-- 0.  DATABASE AND SCHEMA
-- ============================================================
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'Se7tek_DWH')
BEGIN
    CREATE DATABASE Se7tek_DWH;
END
GO

USE Se7tek_DWH;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dwh')
    EXEC('CREATE SCHEMA dwh');
GO

-- ============================================================
-- SAFE DROP  (reverse dependency order — facts first, dims last)
-- ============================================================
IF OBJECT_ID('dwh.Fact_Pregnancy_Monitoring',       'U') IS NOT NULL DROP TABLE dwh.Fact_Pregnancy_Monitoring;
IF OBJECT_ID('dwh.Fact_Content_Views',              'U') IS NOT NULL DROP TABLE dwh.Fact_Content_Views;
IF OBJECT_ID('dwh.Fact_Alert_Response',             'U') IS NOT NULL DROP TABLE dwh.Fact_Alert_Response;
IF OBJECT_ID('dwh.Fact_Medication_Adherence',       'U') IS NOT NULL DROP TABLE dwh.Fact_Medication_Adherence;
IF OBJECT_ID('dwh.Fact_Medical_Analysis_Results',   'U') IS NOT NULL DROP TABLE dwh.Fact_Medical_Analysis_Results;
IF OBJECT_ID('dwh.Fact_Appointments',               'U') IS NOT NULL DROP TABLE dwh.Fact_Appointments;
IF OBJECT_ID('dwh.Dim_Pregnancy',                   'U') IS NOT NULL DROP TABLE dwh.Dim_Pregnancy;
IF OBJECT_ID('dwh.Dim_Patient',                     'U') IS NOT NULL DROP TABLE dwh.Dim_Patient;
IF OBJECT_ID('dwh.Dim_Doctor',                      'U') IS NOT NULL DROP TABLE dwh.Dim_Doctor;
IF OBJECT_ID('dwh.Dim_Medication',                  'U') IS NOT NULL DROP TABLE dwh.Dim_Medication;
IF OBJECT_ID('dwh.Dim_Content',                     'U') IS NOT NULL DROP TABLE dwh.Dim_Content;
IF OBJECT_ID('dwh.Dim_Alert',                       'U') IS NOT NULL DROP TABLE dwh.Dim_Alert;
IF OBJECT_ID('dwh.Dim_Analysis_Type',               'U') IS NOT NULL DROP TABLE dwh.Dim_Analysis_Type;
IF OBJECT_ID('dwh.Dim_Date',                        'U') IS NOT NULL DROP TABLE dwh.Dim_Date;
GO

-- ============================================================
-- 1.  DIM_DATE (FIXED)
--     One row per calendar day.
--     Populated by sp_Load_Dim_Date (section 16).
--     DateKey format: YYYYMMDD (e.g. 20240315) — integer,
--     sorts correctly, human-readable in BI tools.
-- ============================================================
CREATE TABLE dwh.Dim_Date (
    DateKey             INT             NOT NULL,   -- YYYYMMDD

    -- ── Calendar attributes ──────────────────────────────
    Full_Date           DATE            NOT NULL,
    Day_Number          TINYINT         NOT NULL,   -- 1-31
    Day_Name            NVARCHAR(10)    NOT NULL,
    Day_Of_Week         SMALLINT        NOT NULL,   -- 1=Monday, 7=Sunday
    Day_Of_Year         SMALLINT        NOT NULL,   -- 1-366
    
    Week_Number         TINYINT         NOT NULL,   -- ISO week 1-53
    Month_Number        TINYINT         NOT NULL,   -- 1-12
    Month_Name          NVARCHAR(10)    NOT NULL,
    Month_Short         NCHAR(3)        NOT NULL,   -- 'Jan', 'Feb', etc.
    
    Quarter_Number      TINYINT         NOT NULL,   -- 1-4
    Quarter_Label       NCHAR(2)        NOT NULL,   -- 'Q1', 'Q2', 'Q3', 'Q4'
    Year_Number         SMALLINT        NOT NULL,   -- e.g. 2024

    -- ── Derived flags (useful in BI slicers) ─────────────
    Is_Weekend          BIT             NOT NULL,
    Is_Weekday          BIT             NOT NULL,
    Is_Last_Day_Of_Month BIT            NOT NULL,

    -- ── Relative helpers (recalculated during ETL) ───────
    Is_Current_Day      BIT             NOT NULL DEFAULT 0,
    Is_Current_Month    BIT             NOT NULL DEFAULT 0,
    Is_Current_Year     BIT             NOT NULL DEFAULT 0,

    CONSTRAINT pk_dim_date PRIMARY KEY (DateKey)
);
GO

-- ============================================================
-- 2.  DIM_ANALYSIS_TYPE
--     Reference table for lab / clinical analysis categories.
--     Stores normal reference ranges so abnormality flags can
--     be computed at query time (no hard-coded thresholds in
--     the fact table).
-- ============================================================
CREATE TABLE dwh.Dim_Analysis_Type (
    AnalysisTypeKey     INT             IDENTITY(1,1) NOT NULL,
    Analysis_Name       NVARCHAR(100)   NOT NULL,   -- matches OLTP analysis_type
    Category            NVARCHAR(100)   NULL,       -- e.g. 'Haematology', 'Endocrinology'
    Normal_Range_Min    DECIMAL(10,2)   NULL,
    Normal_Range_Max    DECIMAL(10,2)   NULL,

    Created_At          DATETIME2       NOT NULL DEFAULT GETDATE(),
    CONSTRAINT pk_dim_analysis_type PRIMARY KEY (AnalysisTypeKey),
    CONSTRAINT uq_analysis_name     UNIQUE      (Analysis_Name)
);
GO

-- ============================================================
-- 3.  DIM_ALERT
--     Describes alert definitions (static reference data).
--     Severity is stored as both a label and a numeric rank
--     so BI tools can sort by severity without a CASE.
-- ============================================================
CREATE TABLE dwh.Dim_Alert (
    AlertKey            INT             IDENTITY(1,1) NOT NULL,
    AlertID             INT             NOT NULL,   -- OLTP alert_id

    Alert_Title         NVARCHAR(200)   NOT NULL,
    Alert_Description   NVARCHAR(MAX)   NULL,
    Severity_Level      NVARCHAR(20)    NOT NULL,   -- 'Info' | 'Warning' | 'Critical'
    Severity_Rank       TINYINT         NOT NULL,   -- 1=Info, 2=Warning, 3=Critical

    Source_Created_At   DATETIME2       NOT NULL,
    DWH_Loaded_At       DATETIME2       NOT NULL DEFAULT GETDATE(),

    CONSTRAINT pk_dim_alert  PRIMARY KEY (AlertKey),
    CONSTRAINT uq_alert_id   UNIQUE      (AlertID)
);
GO

-- ============================================================
-- 4.  DIM_CONTENT
--     Educational / support content items.
--     Pregnancy week window kept so analysts can ask
--     "which content was consumed at which gestation stage".
-- ============================================================
CREATE TABLE dwh.Dim_Content (
    ContentKey          INT             IDENTITY(1,1) NOT NULL,
    ContentID           INT             NOT NULL,   -- OLTP content_id

    Title               NVARCHAR(200)   NOT NULL,
    Category            NVARCHAR(50)    NULL,       -- 'Support'|'Alert'|'Tip'|'FAQ'|'Guide'
    Target_Week_Start   INT             NULL,
    Target_Week_End     INT             NULL,
    Published_At        DATETIME2       NULL,

    Source_Created_At   DATETIME2       NOT NULL,
    DWH_Loaded_At       DATETIME2       NOT NULL DEFAULT GETDATE(),

    CONSTRAINT pk_dim_content  PRIMARY KEY (ContentKey),
    CONSTRAINT uq_content_id   UNIQUE      (ContentID)
);
GO

-- ============================================================
-- 5.  DIM_MEDICATION
--     Drug reference data.  SCD Type 1 (overwrite on change)
--     because a medication's name or category changing is a
--     data-correction, not a business event worth tracking.
-- ============================================================
CREATE TABLE dwh.Dim_Medication (
    MedKey              INT             IDENTITY(1,1) NOT NULL,
    MedicationID        INT             NOT NULL,   -- OLTP medication_id
    Trade_Name          NVARCHAR(150)   NOT NULL,   -- OLTP: name
    Generic_Name        NVARCHAR(150)   NULL,
    Category            NVARCHAR(100)   NULL,
    Description         NVARCHAR(MAX)   NULL,
    Source_Created_At   DATETIME2       NOT NULL,
    DWH_Loaded_At       DATETIME2       NOT NULL DEFAULT GETDATE(),

    CONSTRAINT pk_dim_medication  PRIMARY KEY (MedKey),
    CONSTRAINT uq_medication_id   UNIQUE      (MedicationID)
);
GO

-- ============================================================
-- 6.  DIM_DOCTOR
--     SCD Type 1 — doctor profile changes are corrections.
--     Specialisation is included for drill-down analysis
--     (e.g. "alerts raised by specialty").
-- ============================================================
CREATE TABLE dwh.Dim_Doctor (
    DoctorKey           INT             IDENTITY(1,1) NOT NULL,
    DoctorID            INT             NOT NULL,   -- OLTP doctor_id
    Doctor_Name         NVARCHAR(150)   NOT NULL,
    Specialty           NVARCHAR(100)   NULL,
    Phone               NVARCHAR(20)    NULL,
    Email               NVARCHAR(150)   NULL,
    Source_Created_At   DATETIME2       NOT NULL,
    DWH_Loaded_At       DATETIME2       NOT NULL DEFAULT GETDATE(),

    CONSTRAINT pk_dim_doctor  PRIMARY KEY (DoctorKey),
    CONSTRAINT uq_doctor_id   UNIQUE      (DoctorID)
);
GO

-- ============================================================
-- 7.  DIM_PATIENT  (SCD Type 2)
--     Patient demographics change meaningfully over time
--     (BMI, smoking status, address, governorate).
--     Fact rows must join to the version of the patient that
--     was current when the event occurred.
--
--     SCD2 mechanics:
--       INSERT  → new row, Valid_From = today, Valid_To = '9999-12-31',
--                 Is_Current = 1.
--       CHANGE  → old row: Valid_To = yesterday, Is_Current = 0.
--                 new row: Valid_From = today, Valid_To = '9999-12-31',
--                          Is_Current = 1.
--       The ETL proc (sp_Load_Dim_Patient) handles this automatically.
-- ============================================================
CREATE TABLE dwh.Dim_Patient (
    PatientKey          INT             IDENTITY(1,1) NOT NULL,
    PatientID           INT             NOT NULL,   -- OLTP patient_id
    Full_Name           NVARCHAR(150)   NOT NULL,
    Date_Of_Birth       DATE            NOT NULL,
    Blood_Type          NVARCHAR(5)     NULL,
    Phone               NVARCHAR(20)    NULL,
    Email               NVARCHAR(150)   NULL,
    Address             NVARCHAR(MAX)   NULL,
    Governorate         NVARCHAR(50)    NULL,
    Emergency_Contact   NVARCHAR(150)   NULL,
    BMI                 DECIMAL(5,2)    NULL,
    Smoker              BIT             NOT NULL DEFAULT 0,
    Previous_Pregnancies INT            NOT NULL DEFAULT 0,

    Age_Band            NVARCHAR(20)    NULL,       -- e.g. '<20','20-24','25-29','30-34','35-39','40+'
    Bmi_Band            NVARCHAR(20)    NULL,

    -- ── SCD2 columns ─────────────────────────────────────
    Valid_From          DATE            NOT NULL,
    Valid_To            DATE            NOT NULL    DEFAULT '9999-12-31',
    Is_Current          BIT             NOT NULL    DEFAULT 1,

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At       DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_dim_patient PRIMARY KEY (PatientKey)
);
GO

-- Index to speed up the "find current row for this patient" lookup
CREATE INDEX idx_dim_patient_id_current
    ON dwh.Dim_Patient (PatientID, Is_Current)
    INCLUDE (PatientKey);
GO

-- ============================================================
-- 8.  DIM_PREGNANCY  (SCD Type 2)
--     Pregnancy attributes that change during the pregnancy:
--       - pregnancy_status  (Active → Completed / Miscarried …)
--       - current_week      (advances weekly)
--       - actual_delivery_date (set at delivery)
--       - abortion_date     (set when terminated/aborted)
--       - is_high_risk / risk_factors (can be reassessed)
--
--     Fixed attributes (Start_Date, Expected_Due_Date,
--     PatientID) never change once a pregnancy is created.
--
--     Parity (number of previous pregnancies at the time
--     this pregnancy was recorded) is denormalised here from
--     Patient_profile.previous_pregnancies for convenience.
-- ============================================================
CREATE TABLE dwh.Dim_Pregnancy (
    PregnancyKey        INT             IDENTITY(1,1) NOT NULL,
    PregnancyID         INT             NOT NULL,   -- OLTP pregnancy_id
    PatientID           INT             NOT NULL,   -- OLTP patient_id (for ETL joins)
    PatientKey          INT             NOT NULL,   -- → dwh.Dim_Patient.PatientKey

    Start_Date          DATE            NOT NULL,
    Expected_Due_Date   DATE            NULL,
    Actual_Delivery_Date   DATE            NULL,

    -- ── Slowly-changing attributes ────────────────────────
    Pregnancy_Status    NVARCHAR(30)    NOT NULL,   -- 'Active'|'Completed'|'Miscarried'|'Terminated'|'Aborted'
    Current_Week        INT             NULL,       -- 1-45; NULL for closed pregnancies
    Abortion_Date       DATE            NULL,       -- for Aborted / Terminated status
    Is_High_Risk        BIT             NOT NULL    DEFAULT 0,
    Risk_Factors        NVARCHAR(200)   NULL,

    -- ── Derived attribute ────────────────────────────────
    Gestation_Days      AS (CASE
                                WHEN Actual_Delivery_Date IS NOT NULL
                                THEN DATEDIFF(DAY, Start_Date, Actual_Delivery_Date)
                                WHEN Abortion_Date IS NOT NULL
                                THEN DATEDIFF(DAY, Start_Date, Abortion_Date)
                                ELSE NULL
                            END),                

    -- ── SCD2 columns ─────────────────────────────────────
    Valid_From          DATE            NOT NULL,
    Valid_To            DATE            NOT NULL    DEFAULT '9999-12-31',
    Is_Current          BIT             NOT NULL    DEFAULT 1,

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At       DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_dim_pregnancy PRIMARY KEY (PregnancyKey),
    CONSTRAINT fk_dpreg_patient
        FOREIGN KEY (PatientKey) REFERENCES dwh.Dim_Patient (PatientKey)
);
GO

CREATE INDEX idx_dim_pregnancy_id_current
    ON dwh.Dim_Pregnancy (PregnancyID, Is_Current)
    INCLUDE (PregnancyKey);
GO

-- ============================================================
-- 9.  FACT_APPOINTMENTS
--     Grain: one row per appointment event.
--     Measures: duration, whether it was a no-show, and
--     the number of days since the patient's last appointment
--     (computed during ETL for trend analysis).
-- ============================================================
CREATE TABLE dwh.Fact_Appointments (
    AppointmentKey      INT             IDENTITY(1,1) NOT NULL,
    PatientKey          INT             NOT NULL,
    DoctorKey           INT             NOT NULL,
    PregnancyKey        INT             NULL,       -- nullable (not every appt links to a pregnancy)
    DateKey             INT             NOT NULL,   -- scheduled date

    -- ── Source key ───────────────────────────────────────
    AppointmentID       INT             NOT NULL,   -- OLTP appointment_id

    -- ── Degenerate dimensions (low cardinality labels) ───
    Appointment_Type    NVARCHAR(80)    NULL,
    Appointment_Status  NVARCHAR(30)    NOT NULL,   -- 'Scheduled'|'Completed'|'Cancelled'|'No-Show'
    Location            NVARCHAR(200)   NULL,

    -- ── Measures ─────────────────────────────────────────
    Duration_Minutes    INT             NULL,
    Is_No_Show          BIT             NOT NULL    DEFAULT 0,   -- 1 when status = 'No-Show'
    Days_Since_Last_Visit INT           NULL,       -- days from previous appt for same patient

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At       DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_fact_appointments   PRIMARY KEY (AppointmentKey),
    CONSTRAINT uq_fact_appt_source    UNIQUE      (AppointmentID),

    CONSTRAINT fk_fact_appt_patient   FOREIGN KEY (PatientKey)   REFERENCES dwh.Dim_Patient   (PatientKey),
    CONSTRAINT fk_fact_appt_doctor    FOREIGN KEY (DoctorKey)    REFERENCES dwh.Dim_Doctor    (DoctorKey),
    CONSTRAINT fk_fact_appt_pregnancy FOREIGN KEY (PregnancyKey) REFERENCES dwh.Dim_Pregnancy (PregnancyKey),
    CONSTRAINT fk_fact_appt_date      FOREIGN KEY (DateKey)      REFERENCES dwh.Dim_Date      (DateKey)
);
GO

-- ============================================================
-- 10. FACT_MEDICAL_ANALYSIS_RESULTS
--     Grain: one row per lab / clinical result.
--     Deviation from mean and abnormal flag allow risk-score
--     calculations without re-reading Dim_Analysis_Type.
-- ============================================================
CREATE TABLE dwh.Fact_Medical_Analysis_Results (
    MedicalAnalysisKey      INT             IDENTITY(1,1) NOT NULL,
    PatientKey              INT             NOT NULL,
    DoctorKey               INT             NULL,       -- nullable (lab result may have no doctor)
    PregnancyKey            INT             NULL,
    AnalysisTypeKey         INT             NOT NULL,
    DateKey                 INT             NOT NULL,   -- result_date
    AnalysisID              INT             NOT NULL,   -- OLTP analysis_id

    Lab_Name                NVARCHAR(150)   NULL,

    -- ── Measures ─────────────────────────────────────────
    Numeric_Result_Value    DECIMAL(10,2)   NULL,
    Result_Deviation_From_Normal DECIMAL(10,2) NULL,   -- result − Normal_Range_Min (negative = below range)
    Is_Abnormal_Flag        BIT             NOT NULL    DEFAULT 0,

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At           DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_fact_analysis   PRIMARY KEY (MedicalAnalysisKey),
    CONSTRAINT uq_fact_analysis_src UNIQUE   (AnalysisID),

    CONSTRAINT fk_fact_ana_patient  FOREIGN KEY (PatientKey)      REFERENCES dwh.Dim_Patient      (PatientKey),
    CONSTRAINT fk_fact_ana_doctor   FOREIGN KEY (DoctorKey)       REFERENCES dwh.Dim_Doctor       (DoctorKey),
    CONSTRAINT fk_fact_ana_preg     FOREIGN KEY (PregnancyKey)    REFERENCES dwh.Dim_Pregnancy    (PregnancyKey),
    CONSTRAINT fk_fact_ana_type     FOREIGN KEY (AnalysisTypeKey) REFERENCES dwh.Dim_Analysis_Type(AnalysisTypeKey),
    CONSTRAINT fk_fact_ana_date     FOREIGN KEY (DateKey)         REFERENCES dwh.Dim_Date         (DateKey)
);
GO

-- ============================================================
-- 11. FACT_MEDICATION_ADHERENCE (FIXED)
--     Grain: one row per scheduled dose (one entry in
--     dbo.adminstration in the OLTP).
--     ScheduleKey links back to the specific prescription so
--     compliance can be analysed per-drug, per-pregnancy,
--     and per-prescribing-doctor independently.
-- ============================================================
CREATE TABLE dwh.Fact_Medication_Adherence (
    AdherenceKey        INT             IDENTITY(1,1) NOT NULL,
    PatientKey          INT             NOT NULL,
    DoctorKey           INT             NULL,       -- prescribing doctor (from Medication_schedule)
    MedKey              INT             NOT NULL,
    PregnancyKey        INT             NULL,
    DateKey             INT             NOT NULL,   -- date of the scheduled dose (taken_at date part)

    ScheduleID          INT             NOT NULL,   -- ADDED: OLTP schedule_id
    Taken_At            DATETIME2       NOT NULL,   -- OLTP taken_at (full timestamp kept)

    Dose_Status         NVARCHAR(30)    NOT NULL,   -- 'Taken'|'Missed'|'Skipped'|'Late'
    Is_Taken            BIT             NOT NULL    DEFAULT 0,
    Is_Missed           BIT             NOT NULL    DEFAULT 0,

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At       DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_fact_adherence    PRIMARY KEY (AdherenceKey),
    CONSTRAINT uq_fact_adh_source   UNIQUE      (ScheduleID, Taken_At),

    CONSTRAINT fk_fact_adh_patient  FOREIGN KEY (PatientKey)  REFERENCES dwh.Dim_Patient  (PatientKey),
    CONSTRAINT fk_fact_adh_doctor   FOREIGN KEY (DoctorKey)   REFERENCES dwh.Dim_Doctor   (DoctorKey),
    CONSTRAINT fk_fact_adh_med      FOREIGN KEY (MedKey)      REFERENCES dwh.Dim_Medication(MedKey),
    CONSTRAINT fk_fact_adh_preg     FOREIGN KEY (PregnancyKey)REFERENCES dwh.Dim_Pregnancy (PregnancyKey),
    CONSTRAINT fk_fact_adh_date     FOREIGN KEY (DateKey)     REFERENCES dwh.Dim_Date     (DateKey)
);
GO

-- ============================================================
-- 12. FACT_ALERT_RESPONSE (FIXED)
--     Grain: one row per alert raised against a pregnancy.
--     Resolution_Time_Hours measures how fast the doctor
--     responded; Is_Escalated flags alerts that took > 24 h.
-- ============================================================
CREATE TABLE dwh.Fact_Alert_Response (
    AlertResponseKey        INT             IDENTITY(1,1) NOT NULL,

    -- ── Dimension foreign keys ───────────────────────────
    PatientKey              INT             NOT NULL,
    DoctorKey               INT             NOT NULL,
    AlertKey                INT             NOT NULL,
    PregnancyKey            INT             NOT NULL,   -- ADDED
    Raised_DateKey          INT             NOT NULL,   -- RENAMED from DateKey
    
    -- ── Source keys ──────────────────────────────────────
    -- OLTP composite PK: (doctor_id, pregnancy_id, alert_id)
    -- stored individually so we can join back without
    -- dereferencing the surrogate keys
    OLTP_DoctorID           INT             NOT NULL,
    OLTP_PregnancyID        INT             NOT NULL,
    OLTP_AlertID            INT             NOT NULL,

    -- ── Measures ─────────────────────────────────────────
    Resolution_Time_Seconds   DECIMAL(10,2)   NULL,       -- NULL if still open
    Is_Resolved             BIT             NOT NULL    DEFAULT 0,
    Is_Escalated            BIT             NOT NULL    DEFAULT 0,   -- 1 if > 24 h to resolve

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At           DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_fact_alert        PRIMARY KEY (AlertResponseKey),
    CONSTRAINT uq_fact_alert_source UNIQUE      (OLTP_DoctorID, OLTP_PregnancyID, OLTP_AlertID),

    CONSTRAINT fk_fact_alr_patient  FOREIGN KEY (PatientKey)      REFERENCES dwh.Dim_Patient  (PatientKey),
    CONSTRAINT fk_fact_alr_doctor   FOREIGN KEY (DoctorKey)       REFERENCES dwh.Dim_Doctor   (DoctorKey),
    CONSTRAINT fk_fact_alr_alert    FOREIGN KEY (AlertKey)        REFERENCES dwh.Dim_Alert    (AlertKey),
    CONSTRAINT fk_fact_alr_preg     FOREIGN KEY (PregnancyKey)    REFERENCES dwh.Dim_Pregnancy (PregnancyKey),  -- FIXED
    CONSTRAINT fk_fact_alr_date     FOREIGN KEY (Raised_DateKey)  REFERENCES dwh.Dim_Date     (DateKey)
);
GO

-- ============================================================
-- 13. FACT_CONTENT_VIEWS
--     Grain: one row per content-view event.
--     (One patient opening one article once = one row.)
--     View_Duration_Seconds is optional — populated only if
--     the OLTP app begins logging read time.
-- ============================================================
CREATE TABLE dwh.Fact_Content_Views (
    ContentViewKey          INT             IDENTITY(1,1) NOT NULL,
    PatientKey              INT             NOT NULL,
    ContentKey              INT             NOT NULL,
    DateKey                 INT             NOT NULL,   -- viewed_at date part

    -- ── Source keys ──────────────────────────────────────
    OLTP_PregnancyID        INT             NULL,       -- preg_content.pregnancy_id
    OLTP_ContentID          INT             NOT NULL,   -- preg_content.content_id

    Is_View                 BIT             NOT NULL    DEFAULT 0,   -- 1 if this was the patient's first view of this article

    -- ── Audit ────────────────────────────────────────────
    DWH_Loaded_At           DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_fact_content_views    PRIMARY KEY (ContentViewKey),
    CONSTRAINT uq_fact_cv_source        UNIQUE      (OLTP_PregnancyID, OLTP_ContentID),

    CONSTRAINT fk_fact_cv_patient   FOREIGN KEY (PatientKey)  REFERENCES dwh.Dim_Patient  (PatientKey),
    CONSTRAINT fk_fact_cv_content   FOREIGN KEY (ContentKey)  REFERENCES dwh.Dim_Content  (ContentKey),
    CONSTRAINT fk_fact_cv_date      FOREIGN KEY (DateKey)     REFERENCES dwh.Dim_Date     (DateKey)
);
GO

-- ============================================================
-- 14. FACT_PREGNANCY_MONITORING  (accumulating snapshot)
--     Grain: one row per pregnancy (never duplicated).
--     Updated in-place as milestones are reached.
--     Milestone date keys are NULL until the milestone occurs.
--
--     KPI measures:
--       Total_Appointments, Total_Missed_Appointments
--       Total_Lab_Results,  Total_Abnormal_Results
--       Total_Scheduled_Doses, Total_Missed_Doses
--       Adherence_Rate_Pct  (computed from above two)
--       Latest_Hb, Latest_HbA1c  (latest lab values)
--       Risk_Score          (0-100 composite, updated by ETL)
--       Gestation_Weeks_At_First_Visit
-- ============================================================
CREATE TABLE dwh.Fact_Pregnancy_Monitoring (
    PregnancyMonitoringKey  INT             IDENTITY(1,1) NOT NULL,
    PregnancyKey            INT             NOT NULL,
    PatientKey              INT             NOT NULL,
    DoctorKey               INT             NULL,       -- primary responsible doctor

    -- ── Milestone date keys ───────────────────────────────
    Start_DateKey           INT             NOT NULL,   -- pregnancy start date
    Due_DateKey             INT             NULL,       -- expected_due_date
    Delivery_DateKey        INT             NULL,       -- actual_delivery_date  (set at birth)
    Abortion_DateKey        INT             NULL,       -- abortion_date         (set when applicable)
    First_Visit_DateKey     INT             NULL,       -- first appointment date

    -- ── Source key ───────────────────────────────────────
    PregnancyID             INT             NOT NULL,   -- OLTP pregnancy_id

    Pregnancy_Status        NVARCHAR(30)    NOT NULL,
    Is_High_Risk            BIT             NOT NULL    DEFAULT 0,

    -- ── KPI measures ─────────────────────────────────────
    Gestation_Weeks_At_First_Visit  INT     NULL,
    Total_Appointments              INT     NOT NULL    DEFAULT 0,
    Total_Missed_Appointments       INT     NOT NULL    DEFAULT 0,
    Total_Lab_Results               INT     NOT NULL    DEFAULT 0,
    Total_Scheduled_Doses           INT     NOT NULL    DEFAULT 0,
    Total_Missed_Doses              INT     NOT NULL    DEFAULT 0,
    Adherence_Rate_Pct              DECIMAL(5,2) NULL,  -- (Total_Scheduled_Doses - Total_Missed_Doses)
                                                       --  / Total_Scheduled_Doses * 100
    Latest_Hb                       DECIMAL(5,2) NULL,  -- most recent haemoglobin result
    Latest_HbA1c                    DECIMAL(5,2) NULL,  -- most recent HbA1c result
    Risk_Score                      DECIMAL(5,2) NULL,  -- 0-100 composite risk score

    -- ── Audit ────────────────────────────────────────────
    Last_Refreshed_At       DATETIME2       NOT NULL    DEFAULT GETDATE(),

    CONSTRAINT pk_fact_preg_monitoring  PRIMARY KEY (PregnancyMonitoringKey),
    CONSTRAINT uq_fact_pm_pregnancy     UNIQUE      (PregnancyID),

    CONSTRAINT fk_fact_pm_pregnancy FOREIGN KEY (PregnancyKey)       REFERENCES dwh.Dim_Pregnancy (PregnancyKey),
    CONSTRAINT fk_fact_pm_patient   FOREIGN KEY (PatientKey)         REFERENCES dwh.Dim_Patient   (PatientKey),
    CONSTRAINT fk_fact_pm_doctor    FOREIGN KEY (DoctorKey)          REFERENCES dwh.Dim_Doctor    (DoctorKey),
    CONSTRAINT fk_fact_pm_start     FOREIGN KEY (Start_DateKey)      REFERENCES dwh.Dim_Date      (DateKey),
    CONSTRAINT fk_fact_pm_due       FOREIGN KEY (Due_DateKey)        REFERENCES dwh.Dim_Date      (DateKey),
    CONSTRAINT fk_fact_pm_delivery  FOREIGN KEY (Delivery_DateKey)   REFERENCES dwh.Dim_Date      (DateKey),
    CONSTRAINT fk_fact_pm_abortion  FOREIGN KEY (Abortion_DateKey)   REFERENCES dwh.Dim_Date      (DateKey),
    CONSTRAINT fk_fact_pm_visit     FOREIGN KEY (First_Visit_DateKey)REFERENCES dwh.Dim_Date      (DateKey)
);
GO

-- ============================================================
-- 15. DWH INDEXES (UPDATED)
--     Cover the most frequent join + filter patterns
--     used by BI tools and analytical queries.
-- ============================================================

-- Fact_Appointments
CREATE INDEX idx_fa_patient    ON dwh.Fact_Appointments (PatientKey);
CREATE INDEX idx_fa_doctor     ON dwh.Fact_Appointments (DoctorKey);
CREATE INDEX idx_fa_pregnancy  ON dwh.Fact_Appointments (PregnancyKey);
CREATE INDEX idx_fa_date       ON dwh.Fact_Appointments (DateKey);
CREATE INDEX idx_fa_status     ON dwh.Fact_Appointments (Appointment_Status);

-- Fact_Medical_Analysis_Results
CREATE INDEX idx_fmar_patient   ON dwh.Fact_Medical_Analysis_Results (PatientKey);
CREATE INDEX idx_fmar_type      ON dwh.Fact_Medical_Analysis_Results (AnalysisTypeKey);
CREATE INDEX idx_fmar_date      ON dwh.Fact_Medical_Analysis_Results (DateKey);
CREATE INDEX idx_fmar_abnormal  ON dwh.Fact_Medical_Analysis_Results (Is_Abnormal_Flag) WHERE Is_Abnormal_Flag = 1;

-- Fact_Medication_Adherence
CREATE INDEX idx_fma_patient    ON dwh.Fact_Medication_Adherence (PatientKey);
CREATE INDEX idx_fma_med        ON dwh.Fact_Medication_Adherence (MedKey);
CREATE INDEX idx_fma_date       ON dwh.Fact_Medication_Adherence (DateKey);
CREATE INDEX idx_fma_status     ON dwh.Fact_Medication_Adherence (Dose_Status);
CREATE INDEX idx_fma_missed     ON dwh.Fact_Medication_Adherence (Is_Missed) WHERE Is_Missed = 1;

-- Fact_Alert_Response
CREATE INDEX idx_far_patient    ON dwh.Fact_Alert_Response (PatientKey);
CREATE INDEX idx_far_alert      ON dwh.Fact_Alert_Response (AlertKey);
CREATE INDEX idx_far_preg       ON dwh.Fact_Alert_Response (PregnancyKey);
CREATE INDEX idx_far_rdate      ON dwh.Fact_Alert_Response (Raised_DateKey);

-- Fact_Pregnancy_Monitoring
CREATE INDEX idx_fpm_patient    ON dwh.Fact_Pregnancy_Monitoring (PatientKey);
CREATE INDEX idx_fpm_status     ON dwh.Fact_Pregnancy_Monitoring (Pregnancy_Status);
CREATE INDEX idx_fpm_highrisk   ON dwh.Fact_Pregnancy_Monitoring (Is_High_Risk) WHERE Is_High_Risk = 1;

-- Dim_Date (common BI slicer patterns)
CREATE INDEX idx_dd_year_month  ON dwh.Dim_Date (Year_Number, Month_Number);
CREATE INDEX idx_dd_fulldate    ON dwh.Dim_Date (Full_Date) INCLUDE (DateKey);
GO

-- ============================================================
-- 16. ETL STORED PROCEDURES (FIXED)
--     Each procedure is idempotent (safe to re-run).
--     Run order: Date → static dims → Patient → Pregnancy
--                → all fact tables.
-- ============================================================

-- ──────────────────────────────────────────────────────────
-- sp_Load_Dim_Date (FIXED)
--   Populates Dim_Date from a start year to an end year.
--   Call once at setup, then annually to extend the range.
--   Also refreshes the Is_Current_* relative flags daily.
-- ──────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dwh.sp_Load_Dim_Date
    @StartYear  INT = 2010,
    @EndYear    INT = 2040
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @d DATE = DATEFROMPARTS(@StartYear, 1, 1);
    DECLARE @end DATE = DATEFROMPARTS(@EndYear, 12, 31);

    -- Insert only dates not yet present
    WHILE @d <= @end
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dwh.Dim_Date WHERE DateKey = CONVERT(INT, FORMAT(@d,'yyyyMMdd')))
        BEGIN
            INSERT INTO dwh.Dim_Date (
                DateKey, Full_Date,
                Day_Number, Day_Name, Day_Of_Week, Day_Of_Year,
                Week_Number, Month_Number, Month_Name, Month_Short,
                Quarter_Number, Quarter_Label, Year_Number,
                Is_Weekend, Is_Weekday, Is_Last_Day_Of_Month,
                Is_Current_Day, Is_Current_Month, Is_Current_Year
            )
            VALUES (
                CONVERT(INT, FORMAT(@d,'yyyyMMdd')),
                @d,
                DAY(@d),
                DATENAME(WEEKDAY, @d),
                -- ISO weekday: 1=Mon … 7=Sun
                CASE DATEPART(WEEKDAY, @d)
                    WHEN 1 THEN 7  -- Sun → 7
                    ELSE DATEPART(WEEKDAY, @d) - 1
                END,
                DATEPART(DAYOFYEAR, @d),
                DATEPART(ISO_WEEK, @d),
                MONTH(@d),
                DATENAME(MONTH, @d),
                LEFT(DATENAME(MONTH, @d), 3),
                DATEPART(QUARTER, @d),
                'Q' + CAST(DATEPART(QUARTER, @d) AS NCHAR(1)),
                YEAR(@d),
                -- Is_Weekend: Sat(7) or Sun(1) in @@DATEFIRST=7 default
                CASE WHEN DATEPART(WEEKDAY,@d) IN (1,7) THEN 1 ELSE 0 END,
                CASE WHEN DATEPART(WEEKDAY,@d) IN (1,7) THEN 0 ELSE 1 END,
                CASE WHEN @d = EOMONTH(@d) THEN 1 ELSE 0 END,
                0, 0, 0
            );
        END
        SET @d = DATEADD(DAY, 1, @d);
    END

    -- Refresh relative flags (run this part daily as a lightweight job)
    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    UPDATE dwh.Dim_Date
    SET
        Is_Current_Day   = CASE WHEN Full_Date = @today THEN 1 ELSE 0 END,
        Is_Current_Month = CASE WHEN Year_Number  = YEAR(@today)
                                 AND Month_Number = MONTH(@today) THEN 1 ELSE 0 END,
        Is_Current_Year  = CASE WHEN Year_Number  = YEAR(@today) THEN 1 ELSE 0 END;

    PRINT 'Dim_Date loaded: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows refreshed.';
END;
GO

PRINT 'Database creation completed successfully!';
GO
INSERT INTO [Se7tek_DWH].[dwh].[Dim_Date] (
    [DateKey],
    [Full_Date],
    [Day_Number],
    [Day_Name],
    [Day_Of_Week],
    [Day_Of_Year],
    [Week_Number],
    [Month_Number],
    [Month_Name],
    [Month_Short],
    [Quarter_Number],
    [Quarter_Label],
    [Year_Number],
    [Is_Weekend],
    [Is_Weekday],
    [Is_Last_Day_Of_Month],
    [Is_Current_Day],
    [Is_Current_Month],
    [Is_Current_Year]
)
VALUES (
    -1,                          
    '1900-01-01',                
    0,                           
    '?',                         
    0,                           
    0,                           
    0,                           
    0,                           
    '?',                         
    '?',                        
    0,                           
    '0',                       
    1900,                        
    0,                           
    0,                           
    0,                           
    0,                           
    0,                           
    0                            
);
