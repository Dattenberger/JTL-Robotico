USE [eazybusiness]
GO

PRINT '--- Diagnose Start ---'

-- 1. Check vCustomActionCheck status
SELECT cName, Status, cObjekt, cPkCol, cNotAllowedParamTypesInAction
FROM CustomWorkflows.vCustomActionCheck
WHERE cName = 'spGebindeErstellen'

-- 2. Check Parameters as seen by JTL
SELECT cActionName, nPos, cName, cDataType, cParameterName
FROM CustomWorkflows.vCustomActionParameter
WHERE cActionName = 'spGebindeErstellen'

-- 3. Check if kArtikel exists in tWorkflowObjects
SELECT *
FROM CustomWorkflows.tWorkflowObjects
WHERE cPkColumn = 'kArtikel'

PRINT '--- Diagnose Ende ---'

SELECT * FROM CustomWorkflows.vCustomAction WHERE cName = 'spGebindeErstellen'