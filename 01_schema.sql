-- =====================================================================
-- Sécurité Assurance – Motor Policy and Claims Management Database
-- INDE 513 Project Phase II – SQLite implementation
-- File 1 of 3: table definitions, triggers and views
-- Run with:  sqlite3 securite.db < 01_schema.sql
-- =====================================================================

PRAGMA foreign_keys = ON;

DROP VIEW IF EXISTS v_claim_overview;
DROP VIEW IF EXISTS v_payment_balance;
DROP VIEW IF EXISTS v_policy_overview;
DROP TABLE IF EXISTS CLAIM_DOCUMENT;
DROP TABLE IF EXISTS CLAIM_ASSESSMENT;
DROP TABLE IF EXISTS CLAIM_DAMAGED_PART;
DROP TABLE IF EXISTS CLAIM;
DROP TABLE IF EXISTS PAYMENT;
DROP TABLE IF EXISTS POLICY_COVERAGE;
DROP TABLE IF EXISTS POLICY;
DROP TABLE IF EXISTS COVERAGE_OPTION;
DROP TABLE IF EXISTS VEHICLE;
DROP TABLE IF EXISTS VEHICLE_MODEL;
DROP TABLE IF EXISTS CUSTOMER_PHONE;
DROP TABLE IF EXISTS CUSTOMER;
DROP TABLE IF EXISTS CITY;

-- ---------------------------------------------------------------------
-- CITY  (created in 3NF: City -> District was a transitive dependency in CUSTOMER)
-- ---------------------------------------------------------------------
CREATE TABLE CITY (
    CityName  VARCHAR(40) PRIMARY KEY,
    District  VARCHAR(40) NOT NULL,
    CHECK (length(CityName) BETWEEN 2 AND 40),
    CHECK (length(District) BETWEEN 2 AND 40)
);

-- ---------------------------------------------------------------------
-- CUSTOMER  (strong entity; composite Address flattened; Age derived, not stored)
-- ---------------------------------------------------------------------
CREATE TABLE CUSTOMER (
    CustomerID      INTEGER PRIMARY KEY,
    CustomerNumber  CHAR(8)     NOT NULL UNIQUE,          -- e.g. CU000101
    FullName        VARCHAR(60) NOT NULL,
    DateOfBirth     DATE        NOT NULL,
    Email           VARCHAR(80),                           -- optional
    Street          VARCHAR(80) NOT NULL,
    CityName        VARCHAR(40) NOT NULL,
    FOREIGN KEY (CityName) REFERENCES CITY(CityName),
    CHECK (length(CustomerNumber) = 8 AND CustomerNumber LIKE 'CU%'),
    CHECK (length(FullName) BETWEEN 3 AND 60),
    CHECK (date(DateOfBirth) IS NOT NULL AND DateOfBirth BETWEEN '1920-01-01' AND '2008-12-31'),
    CHECK (Email IS NULL OR Email LIKE '%_@_%._%')
);

-- ---------------------------------------------------------------------
-- CUSTOMER_PHONE  (multivalued attribute PhoneNumbers)
-- ---------------------------------------------------------------------
CREATE TABLE CUSTOMER_PHONE (
    CustomerID   INTEGER     NOT NULL,
    PhoneNumber  VARCHAR(15) NOT NULL,
    PRIMARY KEY (CustomerID, PhoneNumber),
    FOREIGN KEY (CustomerID) REFERENCES CUSTOMER(CustomerID) ON DELETE CASCADE,
    CHECK (length(PhoneNumber) BETWEEN 8 AND 15)
);

-- ---------------------------------------------------------------------
-- VEHICLE_MODEL  (created in 3NF: Model -> Make was a transitive dependency in VEHICLE)
-- ---------------------------------------------------------------------
CREATE TABLE VEHICLE_MODEL (
    ModelName  VARCHAR(30) PRIMARY KEY,
    Make       VARCHAR(30) NOT NULL,
    CHECK (length(ModelName) BETWEEN 1 AND 30),
    CHECK (length(Make) BETWEEN 2 AND 30)
);

-- ---------------------------------------------------------------------
-- VEHICLE  (strong entity; VehicleAge derived, not stored)
-- ---------------------------------------------------------------------
CREATE TABLE VEHICLE (
    VehicleID        INTEGER PRIMARY KEY,
    ChassisNumber    CHAR(17)    NOT NULL UNIQUE,         -- 17-character VIN
    PlateNumber      VARCHAR(10) NOT NULL UNIQUE,
    ModelName        VARCHAR(30) NOT NULL,
    ManufactureYear  INTEGER     NOT NULL,
    FOREIGN KEY (ModelName) REFERENCES VEHICLE_MODEL(ModelName),
    CHECK (length(ChassisNumber) = 17),
    CHECK (ManufactureYear BETWEEN 1980 AND 2027)
);

-- ---------------------------------------------------------------------
-- COVERAGE_OPTION  (catalogue of covers)
-- ---------------------------------------------------------------------
CREATE TABLE COVERAGE_OPTION (
    OptionID       INTEGER PRIMARY KEY,
    OptionCode     CHAR(5)       NOT NULL UNIQUE,
    OptionName     VARCHAR(50)   NOT NULL,
    Description    VARCHAR(200),                          -- optional
    StandardLimit  DECIMAL(12,2),                         -- optional
    IsAvailable    INTEGER       NOT NULL DEFAULT 1,
    CHECK (length(OptionCode) = 5),
    CHECK (StandardLimit IS NULL OR StandardLimit > 0),
    CHECK (IsAvailable IN (0, 1))
);

-- ---------------------------------------------------------------------
-- POLICY  (HOLDS 1:N -> CustomerID FK; COVERS 1:1 -> VehicleID FK + UNIQUE)
-- ---------------------------------------------------------------------
CREATE TABLE POLICY (
    PolicyID       INTEGER PRIMARY KEY,
    PolicyNumber   CHAR(13)      NOT NULL UNIQUE,         -- e.g. MTR-2026-0001
    CustomerID     INTEGER       NOT NULL,
    VehicleID      INTEGER       NOT NULL UNIQUE,         -- one policy per vehicle
    StartDate      DATE          NOT NULL,
    EndDate        DATE          NOT NULL,
    PremiumAmount  DECIMAL(10,2) NOT NULL,
    Currency       CHAR(3)       NOT NULL DEFAULT 'USD',
    Status         VARCHAR(10)   NOT NULL DEFAULT 'Active',
    FOREIGN KEY (CustomerID) REFERENCES CUSTOMER(CustomerID),
    FOREIGN KEY (VehicleID)  REFERENCES VEHICLE(VehicleID),
    CHECK (length(PolicyNumber) = 13 AND PolicyNumber LIKE 'MTR-____-____'),
    CHECK (date(StartDate) IS NOT NULL AND date(EndDate) IS NOT NULL AND StartDate < EndDate),
    CHECK (PremiumAmount > 0),
    CHECK (Currency IN ('USD', 'LBP')),
    CHECK (Status IN ('Active', 'Expired', 'Cancelled'))
);

-- ---------------------------------------------------------------------
-- POLICY_COVERAGE  (M:N relationship SELECTS with its own attributes)
-- ---------------------------------------------------------------------
CREATE TABLE POLICY_COVERAGE (
    PolicyID       INTEGER       NOT NULL,
    OptionID       INTEGER       NOT NULL,
    SelectedLimit  DECIMAL(12,2) NOT NULL,
    Deductible     DECIMAL(10,2) NOT NULL DEFAULT 0,
    CoverPremium   DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (PolicyID, OptionID),
    FOREIGN KEY (PolicyID) REFERENCES POLICY(PolicyID) ON DELETE CASCADE,
    FOREIGN KEY (OptionID) REFERENCES COVERAGE_OPTION(OptionID),
    CHECK (SelectedLimit > 0),
    CHECK (Deductible >= 0 AND Deductible < SelectedLimit),
    CHECK (CoverPremium >= 0)
);

-- A policy may include at most four coverage options: SELECTS POLICY (1,4)
CREATE TRIGGER trg_max_four_covers
BEFORE INSERT ON POLICY_COVERAGE
WHEN (SELECT COUNT(*) FROM POLICY_COVERAGE WHERE PolicyID = NEW.PolicyID) >= 4
BEGIN
    SELECT RAISE(ABORT, 'A policy cannot include more than four coverage options');
END;

-- ---------------------------------------------------------------------
-- PAYMENT  (SCHEDULES 1:N -> PolicyID FK; Balance derived, not stored)
-- ---------------------------------------------------------------------
CREATE TABLE PAYMENT (
    PaymentID      INTEGER PRIMARY KEY,
    PolicyID       INTEGER       NOT NULL,
    InstallmentNo  INTEGER       NOT NULL,
    DueDate        DATE          NOT NULL,
    AmountDue      DECIMAL(10,2) NOT NULL,
    AmountPaid     DECIMAL(10,2) NOT NULL DEFAULT 0,
    PaidDate       DATE,                                  -- optional until paid
    PaymentStatus  VARCHAR(10)   NOT NULL DEFAULT 'Pending',
    UNIQUE (PolicyID, InstallmentNo),
    FOREIGN KEY (PolicyID) REFERENCES POLICY(PolicyID) ON DELETE CASCADE,
    CHECK (InstallmentNo BETWEEN 1 AND 12),               -- SCHEDULES POLICY (1,12)
    CHECK (AmountDue > 0),
    CHECK (AmountPaid >= 0 AND AmountPaid <= AmountDue),
    CHECK (PaymentStatus IN ('Pending', 'Partial', 'Paid', 'Cancelled')),
    CHECK (PaidDate IS NULL OR AmountPaid > 0)
);

-- ---------------------------------------------------------------------
-- CLAIM  (RECEIVES 1:N -> PolicyID FK; ProcessingDays derived, not stored)
-- ---------------------------------------------------------------------
CREATE TABLE CLAIM (
    ClaimID         INTEGER PRIMARY KEY,
    ClaimReference  CHAR(12)      NOT NULL UNIQUE,        -- e.g. CLM-2026-001
    PolicyID        INTEGER       NOT NULL,
    IncidentDate    DATE          NOT NULL,
    ReportedDate    DATE          NOT NULL,
    Description     VARCHAR(250)  NOT NULL,
    ClaimedAmount   DECIMAL(10,2),                        -- optional until estimated
    ClaimStatus     VARCHAR(12)   NOT NULL DEFAULT 'Reported',
    ClosedDate      DATE,                                 -- optional until closed
    FOREIGN KEY (PolicyID) REFERENCES POLICY(PolicyID),
    CHECK (length(ClaimReference) = 12 AND ClaimReference LIKE 'CLM-____-___'),
    CHECK (ReportedDate >= IncidentDate),
    CHECK (ClosedDate IS NULL OR ClosedDate >= ReportedDate),
    CHECK (ClaimedAmount IS NULL OR ClaimedAmount > 0),
    CHECK (ClaimStatus IN ('Reported', 'Under Review', 'Approved', 'Rejected', 'Closed'))
);

-- The incident must fall within the policy term
CREATE TRIGGER trg_claim_within_term
BEFORE INSERT ON CLAIM
WHEN NOT EXISTS (SELECT 1 FROM POLICY p
                 WHERE p.PolicyID = NEW.PolicyID
                   AND NEW.IncidentDate BETWEEN p.StartDate AND p.EndDate)
BEGIN
    SELECT RAISE(ABORT, 'Incident date is outside the policy term');
END;

-- ---------------------------------------------------------------------
-- CLAIM_DAMAGED_PART  (multivalued attribute DamagedParts)
-- ---------------------------------------------------------------------
CREATE TABLE CLAIM_DAMAGED_PART (
    ClaimID   INTEGER     NOT NULL,
    PartName  VARCHAR(30) NOT NULL,
    PRIMARY KEY (ClaimID, PartName),
    FOREIGN KEY (ClaimID) REFERENCES CLAIM(ClaimID) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- CLAIM_ASSESSMENT  (HAS ASSESSMENT 1:1 -> ClaimID FK + UNIQUE + NOT NULL)
-- ---------------------------------------------------------------------
CREATE TABLE CLAIM_ASSESSMENT (
    AssessmentID    INTEGER PRIMARY KEY,
    ClaimID         INTEGER       NOT NULL UNIQUE,
    AssessmentDate  DATE          NOT NULL,
    EstimatedLoss   DECIMAL(10,2) NOT NULL,
    Decision        VARCHAR(8)    NOT NULL,
    ApprovedAmount  DECIMAL(10,2),                        -- only when approved
    Remarks         VARCHAR(250),                         -- optional
    FOREIGN KEY (ClaimID) REFERENCES CLAIM(ClaimID) ON DELETE CASCADE,
    CHECK (EstimatedLoss >= 0),
    CHECK (Decision IN ('Approved', 'Rejected')),
    CHECK ((Decision = 'Approved' AND ApprovedAmount IS NOT NULL AND ApprovedAmount > 0)
        OR (Decision = 'Rejected' AND ApprovedAmount IS NULL))
);

-- ---------------------------------------------------------------------
-- CLAIM_DOCUMENT  (weak entity: PK = owner key ClaimID + partial key DocumentNo)
-- ---------------------------------------------------------------------
CREATE TABLE CLAIM_DOCUMENT (
    ClaimID             INTEGER     NOT NULL,
    DocumentNo          INTEGER     NOT NULL,
    FileName            VARCHAR(80) NOT NULL,
    DocumentType        VARCHAR(20) NOT NULL,
    ReceivedDate        DATE        NOT NULL,
    VerificationStatus  VARCHAR(10) NOT NULL DEFAULT 'Pending',
    FileLocation        VARCHAR(120),                     -- optional until digitised
    PRIMARY KEY (ClaimID, DocumentNo),
    FOREIGN KEY (ClaimID) REFERENCES CLAIM(ClaimID) ON DELETE CASCADE,
    CHECK (DocumentNo >= 1),
    CHECK (DocumentType IN ('Accident Report', 'Police Report', 'Photo', 'Repair Quote', 'Invoice', 'Other')),
    CHECK (VerificationStatus IN ('Pending', 'Verified', 'Rejected'))
);

-- ---------------------------------------------------------------------
-- Views that compute the derived attributes (they are not stored)
-- ---------------------------------------------------------------------
CREATE VIEW v_policy_overview AS
SELECT p.PolicyID, p.PolicyNumber, p.Status, p.StartDate, p.EndDate,
       CAST(julianday(p.EndDate) - julianday(p.StartDate) AS INTEGER) AS DurationDays,
       p.PremiumAmount, p.Currency,
       c.CustomerID, c.CustomerNumber, c.FullName,
       CAST((julianday('now') - julianday(c.DateOfBirth)) / 365.25 AS INTEGER) AS Age,
       v.VehicleID, v.PlateNumber, m.Make, v.ModelName, v.ManufactureYear,
       CAST(strftime('%Y', 'now') AS INTEGER) - v.ManufactureYear AS VehicleAge
FROM POLICY p
JOIN CUSTOMER c       ON c.CustomerID = p.CustomerID
JOIN VEHICLE v        ON v.VehicleID = p.VehicleID
JOIN VEHICLE_MODEL m  ON m.ModelName = v.ModelName;

CREATE VIEW v_payment_balance AS
SELECT pay.*, ROUND(pay.AmountDue - pay.AmountPaid, 2) AS Balance
FROM PAYMENT pay;

CREATE VIEW v_claim_overview AS
SELECT cl.*,
       CAST(julianday(COALESCE(cl.ClosedDate, date('now'))) - julianday(cl.ReportedDate) AS INTEGER) AS ProcessingDays
FROM CLAIM cl;
