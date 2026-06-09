-- ============================================================================
-- Teardown: Duplicate Order Detection — drops ALL feature objects
-- ============================================================================
--
-- Author:  Lukas Dattenberger
-- Date:    2026-06-09
--
-- Removes every object this feature has ever created: the current boolean
-- architecture, the (since removed) JTL action wrapper, and any leftovers of
-- the v1 logging design. Run this when you want a clean slate, then re-run
-- Duplikaterkennung_Bestellungen.sql so nothing old remains.
--
-- Idempotent (IF OBJECT_ID guards) and transactional. Run against eazybusiness.
--
-- Note: dropping CustomWorkflows.spCheckDuplicateOrder also removes its
-- DisplayName extended property (= the JTL action registration); there is no
-- separate registry table. If that action was wired into a real workflow, the
-- reference in dbo.tWorkflowAktion remains (your workflow config — not touched).
-- ============================================================================

USE [eazybusiness]
GO

SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

-- Dependents first, then dependencies.

-- v2 (current boolean architecture + the action wrapper that once existed)
IF OBJECT_ID('CustomWorkflows.spCheckDuplicateOrder', 'P')  IS NOT NULL DROP PROCEDURE CustomWorkflows.spCheckDuplicateOrder;
IF OBJECT_ID('Robotico.spCheckDuplicateOrder', 'P')         IS NOT NULL DROP PROCEDURE Robotico.spCheckDuplicateOrder;
IF OBJECT_ID('Robotico.fnHasOlderDuplicateOrder', 'FN')     IS NOT NULL DROP FUNCTION  Robotico.fnHasOlderDuplicateOrder;
IF OBJECT_ID('Robotico.fnFindDuplicateOrders', 'IF')        IS NOT NULL DROP FUNCTION  Robotico.fnFindDuplicateOrders;

-- v1 (legacy logging design)
IF OBJECT_ID('CustomWorkflows.spProtokolliereDuplikatBestellung', 'P') IS NOT NULL DROP PROCEDURE CustomWorkflows.spProtokolliereDuplikatBestellung;
IF OBJECT_ID('Robotico.tvfFindeDuplikatAuftraege', 'IF')    IS NOT NULL DROP FUNCTION  Robotico.tvfFindeDuplikatAuftraege;
IF OBJECT_ID('Robotico.tDuplikatBestellungLog', 'U')        IS NOT NULL DROP TABLE     Robotico.tDuplikatBestellungLog;

COMMIT TRANSACTION;
PRINT '+ Teardown complete - all duplicate-order-detection objects removed';
GO
