-- =====================================================================
-- File 3 of 3: queries
-- Each query answers an operational question for the motor line.
-- '2026-11-20' is used as "today" so that results are reproducible.
-- =====================================================================
PRAGMA foreign_keys = ON;

-- Q1 | Filtering + sorting
-- Which active policies expire before the end of March 2027? (renewal follow-up list)
SELECT PolicyNumber, StartDate, EndDate, PremiumAmount, Currency
FROM POLICY
WHERE Status = 'Active' AND EndDate <= '2027-03-31'
ORDER BY EndDate ASC;

-- Q2 | Join across five tables
-- Full profile of every active policy: holder, city/district, vehicle make and model.
SELECT p.PolicyNumber, c.FullName, c.CityName, ci.District,
       m.Make, v.ModelName, v.PlateNumber, p.PremiumAmount
FROM POLICY p
JOIN CUSTOMER c       ON c.CustomerID = p.CustomerID
JOIN CITY ci          ON ci.CityName  = c.CityName
JOIN VEHICLE v        ON v.VehicleID  = p.VehicleID
JOIN VEHICLE_MODEL m  ON m.ModelName  = v.ModelName
WHERE p.Status = 'Active'
ORDER BY p.PolicyNumber;

-- Q3 | Join through the M:N table
-- What does policy MTR-2026-0001 cover, with which limits and deductibles?
SELECT o.OptionCode, o.OptionName, pc.SelectedLimit, pc.Deductible, pc.CoverPremium
FROM POLICY p
JOIN POLICY_COVERAGE pc ON pc.PolicyID = p.PolicyID
JOIN COVERAGE_OPTION o  ON o.OptionID  = pc.OptionID
WHERE p.PolicyNumber = 'MTR-2026-0001'
ORDER BY pc.CoverPremium DESC;

-- Q4 | Aggregation + GROUP BY + HAVING (derived Balance)
-- Which policies have overdue instalments, and how much is outstanding?
SELECT p.PolicyNumber, c.FullName,
       COUNT(*)                                 AS OverdueInstalments,
       ROUND(SUM(pay.AmountDue - pay.AmountPaid), 2) AS OutstandingBalance,
       MIN(pay.DueDate)                         AS OldestDueDate
FROM PAYMENT pay
JOIN POLICY p   ON p.PolicyID   = pay.PolicyID
JOIN CUSTOMER c ON c.CustomerID = p.CustomerID
WHERE pay.DueDate < '2026-11-20'
  AND pay.PaymentStatus IN ('Pending', 'Partial')
GROUP BY p.PolicyNumber, c.FullName
HAVING SUM(pay.AmountDue - pay.AmountPaid) > 0
ORDER BY OutstandingBalance DESC;

-- Q5 | GROUP BY on the M:N table
-- How popular is each coverage option, and how much premium does it bring in?
SELECT o.OptionCode, o.OptionName,
       COUNT(pc.PolicyID)          AS PoliciesUsingIt,
       ROUND(SUM(pc.CoverPremium), 2) AS TotalCoverPremium,
       ROUND(AVG(pc.Deductible), 2)   AS AvgDeductible
FROM COVERAGE_OPTION o
LEFT JOIN POLICY_COVERAGE pc ON pc.OptionID = o.OptionID
GROUP BY o.OptionID, o.OptionCode, o.OptionName
ORDER BY PoliciesUsingIt DESC, TotalCoverPremium DESC;

-- Q6 | GROUP BY + HAVING
-- Which customers insure more than one vehicle with us?
SELECT c.CustomerNumber, c.FullName,
       COUNT(p.PolicyID)          AS Policies,
       ROUND(SUM(p.PremiumAmount), 2) AS TotalPremium
FROM CUSTOMER c
JOIN POLICY p ON p.CustomerID = c.CustomerID
GROUP BY c.CustomerID, c.CustomerNumber, c.FullName
HAVING COUNT(p.PolicyID) > 1
ORDER BY TotalPremium DESC;

-- Q7 | Aggregation on a derived attribute (ProcessingDays)
-- How many claims are in each status, and how long do they take on average?
SELECT ClaimStatus,
       COUNT(*) AS Claims,
       ROUND(AVG(julianday(COALESCE(ClosedDate, '2026-11-20')) - julianday(ReportedDate)), 1) AS AvgProcessingDays,
       ROUND(SUM(ClaimedAmount), 2) AS TotalClaimed
FROM CLAIM
GROUP BY ClaimStatus
ORDER BY Claims DESC;

-- Q8 | Join + aggregation + HAVING
-- Which districts generate more than USD 2,000 in claimed amounts?
SELECT ci.District,
       COUNT(cl.ClaimID)            AS Claims,
       ROUND(SUM(cl.ClaimedAmount), 2) AS TotalClaimed
FROM CLAIM cl
JOIN POLICY p   ON p.PolicyID   = cl.PolicyID
JOIN CUSTOMER c ON c.CustomerID = p.CustomerID
JOIN CITY ci    ON ci.CityName  = c.CityName
GROUP BY ci.District
HAVING SUM(cl.ClaimedAmount) > 2000
ORDER BY TotalClaimed DESC;

-- Q9 | Join on the 1:1 relationship + calculated column
-- For each assessed claim, how much was approved compared with the amount claimed?
SELECT cl.ClaimReference, p.PolicyNumber, cl.ClaimedAmount,
       a.Decision, a.ApprovedAmount,
       ROUND(100.0 * a.ApprovedAmount / cl.ClaimedAmount, 1) AS PctApproved
FROM CLAIM cl
JOIN POLICY p           ON p.PolicyID = cl.PolicyID
JOIN CLAIM_ASSESSMENT a ON a.ClaimID  = cl.ClaimID
ORDER BY cl.ClaimReference;

-- Q10 | LEFT JOIN + IS NULL
-- Which active policies have never had a claim?
SELECT p.PolicyNumber, c.FullName, v.PlateNumber
FROM POLICY p
JOIN CUSTOMER c ON c.CustomerID = p.CustomerID
JOIN VEHICLE v  ON v.VehicleID  = p.VehicleID
LEFT JOIN CLAIM cl ON cl.PolicyID = p.PolicyID
WHERE p.Status = 'Active' AND cl.ClaimID IS NULL
ORDER BY p.PolicyNumber;

-- Q11 | Weak entity + filtering
-- Which documents on open claims are still waiting for verification?
SELECT cl.ClaimReference, cl.ClaimStatus, d.DocumentNo, d.DocumentType, d.ReceivedDate
FROM CLAIM_DOCUMENT d
JOIN CLAIM cl ON cl.ClaimID = d.ClaimID
WHERE d.VerificationStatus = 'Pending'
  AND cl.ClaimStatus IN ('Reported', 'Under Review', 'Approved')
ORDER BY d.ReceivedDate, cl.ClaimReference;

-- Q12 | Multivalued attribute + GROUP BY + HAVING
-- Which car parts are damaged most often?
SELECT PartName, COUNT(*) AS TimesDamaged
FROM CLAIM_DAMAGED_PART
GROUP BY PartName
HAVING COUNT(*) >= 2
ORDER BY TimesDamaged DESC, PartName;

-- Q13 | LIKE search (used by the website search box)
-- Find a customer by part of their name, with their phone numbers.
SELECT c.CustomerNumber, c.FullName, ph.PhoneNumber
FROM CUSTOMER c
JOIN CUSTOMER_PHONE ph ON ph.CustomerID = c.CustomerID
WHERE c.FullName LIKE '%Itani%';
